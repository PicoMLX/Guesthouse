import Foundation

/// Pure transition function for `ProvisioningState`.
///
/// The rules everything else follows from:
/// - A start is reserved synchronously with `startRequested` from `notStarted`, `resumable`, or
///   the previous stage's `completed`, and only then may the runtime be asked; `operationStarted`
///   is legal solely from `startRequested`. Never from a failure, an unknown outcome, or an
///   unpersisted checkpoint, and never twice.
/// - Failure, cancellation, interruption, and user action all lead to an inspection before
///   anything re-runs, so a retry can never blindly repeat a step whose real outcome is unknown
///   (MVP-PLAN.md §3, §4, §9). Inspection can be requested again at any time except while a
///   start request is still live; each request replaces the outstanding one.
/// - Every start request and effect carries a token, and only the callback naming the outstanding
///   token is accepted. Lost effects can be reissued without accepting their earlier replies.
/// - A checkpoint counts only once the journal has it (§3: "Persist ... before updating the UI").
enum ProvisioningReducer: Sendable {
    static func reduce(
        _ state: ProvisioningState,
        _ event: ProvisioningEvent
    ) throws(ProvisioningTransitionError) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
        let stage = state.stage
        var issued = state.issuedEffects
        func mint() -> EffectToken {
            issued += 1
            return EffectToken(issued)
        }
        func at(_ status: StageStatus, _ effects: [ProvisioningEffect] = []) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
            (ProvisioningState(stage: stage, status: status, issuedEffects: issued), effects)
        }
        /// Mints the inspection's token once, so the status and the effect asking for it can
        /// never name different inspections.
        func inspect(operation: OperationID? = nil) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
            let token = mint()
            let status = operation.map { StageStatus.unknownOutcome($0, inspection: token) } ?? .awaitingInspection(token)
            return at(status, [.inspectActualState(stage, token, operation: operation)])
        }
        /// Reserves a start for `requested`, carrying forward the durable partial work the
        /// reservation was made from so a refusal cannot orphan it.
        func reserve(_ requested: ProvisioningStage, resuming: ResumeEvidence?) throws(ProvisioningTransitionError) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
            guard requested == stage else { throw .stageMismatch(expected: stage, actual: requested) }
            return at(.startRequested(request: mint(), resuming: resuming))
        }
        /// Check the request before interpreting its reply: even an acceptance for the wrong
        /// stage must not abandon a newer reservation. Older records have no request identity,
        /// so no callback can settle them; explicit inspection is their recovery path.
        func requireRequest(_ expected: EffectToken?, _ actual: EffectToken) throws(ProvisioningTransitionError) {
            guard let expected else { throw .illegalTransition(status: state.status.caseName, event: event.caseName) }
            guard expected == actual else { throw .staleStartRequest(expected: expected, actual: actual) }
        }
        /// Applies what inspection found. `interrupted` is the operation the reducer was
        /// tracking when contact was lost, when it knows one; a reported identity has to be
        /// that operation, or a second one would be adopted while the first can still mutate.
        func adopt(_ outcome: ReconciledOutcome, interrupted: OperationID?) throws(ProvisioningTransitionError) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
            switch outcome {
            case .completed(let checkpoint):
                // A later checkpoint is adopted: the journal is the durable truth, and pinning
                // the saved stage would offer a start for a step the runtime already ran.
                guard checkpoint.stage >= stage else { throw .stageMismatch(expected: stage, actual: checkpoint.stage) }
                let write = mint()
                let status = StageStatus.persistingCheckpoint(checkpoint, operation: interrupted, write: write)
                return (ProvisioningState(stage: checkpoint.stage, status: status, issuedEffects: issued), [.persistCheckpoint(checkpoint, write)])
            case .stillRunning(let id):
                if let interrupted { try requireSame(interrupted, id) }
                return at(.inProgress(id))
            case .stillNeedsUserAction(let id, let error):
                if let interrupted { try requireSame(interrupted, id) }
                return at(.needsUserAction(id, error))
            case .cleanupRunning(let cleanup, let error):
                return at(.cleanupRequired(error, cleanup: cleanup))
            case .resumable(let evidence):
                return at(.resumable(evidence))
            case .failedNeedsCleanup(let error):
                let cleanup = mint()
                return at(.cleanupRequired(error, cleanup: cleanup), [.cleanUp(stage, cleanup)])
            case .failed(let error):
                return at(.recoverableFailure(error, interrupted: nil))
            case .notStarted:
                return at(.notStarted)
            }
        }

        switch (state.status, event) {

        case (.notStarted, .startRequested(let requested)):
            return try reserve(requested, resuming: nil)

        case (.resumable(let evidence), .startRequested(let requested)):
            return try reserve(requested, resuming: evidence)

        case (.startRejected(_, let resuming), .startRequested(let requested)):
            return try reserve(requested, resuming: resuming)

        case (.completed, .startRequested(let requested)):
            guard let next = stage.next else { throw .alreadyReady }
            guard requested == next else { throw .stageMismatch(expected: next, actual: requested) }
            let request = mint()
            return (ProvisioningState(stage: next, status: .startRequested(request: request, resuming: nil), issuedEffects: issued), [])

        case (.startRequested(let request, _), .operationStarted(let id, let requested, let token)):
            try requireRequest(request, token)
            // This request has answered, so its reservation is no longer live. An acceptance
            // at the wrong stage may already be mutating. Inspect its identity across all stages
            // before reconciling the reserved stage; only that inspection can establish its stage.
            guard requested == stage else { return inspect(operation: id) }
            return at(.inProgress(id))

        case (.startRequested(let request, let resuming), .startRequestRejected(let error, let token)):
            try requireRequest(request, token)
            // The refusal did nothing, so whatever durable partial work the reservation was made
            // from is still there and still has to be resumed from once the refusal is dealt with.
            return at(.startRejected(error, resuming: resuming))

        case (.startRequested(let request, _), .startRequestInterrupted(let token)):
            try requireRequest(request, token)
            return inspect()

        case (.startRequested(nil, _), .inspectionRequested):
            // Only a legacy saved reservation lacks a token. Its old request cannot still be
            // live in this coordinator, and no uncorrelated callback is accepted in its place.
            return inspect()

        case (.startRequested, .inspectionRequested):
            // The reservation stays held: the request is still live, so the runtime may still
            // accept it, and an inspection that reported `notStarted` would let a second start
            // race the first. A dropped connection is reported as `startRequestInterrupted`,
            // which ends the request and does inspect.
            throw .inspectionWhileStartRequestLive

        case (.inProgress(let current), .checkpointReached(let id, let checkpoint)),
             (.needsUserAction(let current, _), .checkpointReached(let id, let checkpoint)):
            // A paused operation resumes as soon as the user does the out-of-app step, which can
            // be before the GUI reports it; refusing its checkpoint would drop a reached one.
            try requireSame(current, id)
            guard checkpoint.stage == stage else { throw .stageMismatch(expected: stage, actual: checkpoint.stage) }
            let write = mint()
            return at(.persistingCheckpoint(checkpoint, operation: current, write: write), [.persistCheckpoint(checkpoint, write)])

        case (.persistingCheckpoint(let pending, _, let write), .checkpointPersisted(let token, let persisted)):
            try requireOutstanding(write, token)
            guard pending == persisted else { throw .checkpointMismatch(expected: pending, actual: persisted) }
            return at(.completed(persisted))

        case (.persistingCheckpoint(_, let writer, let write), .checkpointPersistenceFailed(let token, let error)):
            // Reality is ahead of the journal. The failure is shown with its recovery actions;
            // the user's retry inspects, finds the checkpoint reached, and persists it again.
            // A failed write does not settle its operation, so recovery must keep that identity.
            try requireOutstanding(write, token)
            return at(.recoverableFailure(error, interrupted: writer))

        case (.persistingCheckpoint(_, let writer, _), .connectionInterrupted(let id)):
            // The write's result is unknown; the journal is inspected before anything else.
            // An interruption belonging to another operation says nothing about this write, and
            // a write reconciliation started has no operation behind it at all, so no
            // operation-scoped interruption is about it either: taking one as relevant would
            // abandon a live write and make its own successful callback stale.
            guard let writer else { throw .illegalTransition(status: state.status.caseName, event: event.caseName) }
            try requireSame(writer, id)
            return inspect(operation: writer)

        case (.persistingCheckpoint(_, let writer, _), .userRetried),
             (.persistingCheckpoint(_, let writer, _), .inspectionRequested):
            // The operation that reached the checkpoint keeps its identity through the check,
            // for the same reason every other live operation does: it may still be mutating,
            // and an unscoped inspection would adopt a `stillRunning(B)` naming another one
            // without `requireSame`, leaving the first unaccounted for while the reducer follows
            // the second (MVP-PLAN.md §3). A checkpoint restored after a relaunch is exactly
            // that case: the write is lost, the operation behind it need not be. The unscoped
            // status is left to a reconciled write, which has no operation behind it.
            return inspect(operation: writer)

        case (.inProgress(let current), .operationFailed(let id, let error)),
             (.needsUserAction(let current, _), .operationFailed(let id, let error)):
            // A paused operation can still time out or die with the guest. Keeping the obsolete
            // prompt and discarding the failure would hide why the step stopped (MVP-PLAN.md §9).
            try requireSame(current, id)
            return at(.recoverableFailure(error, interrupted: nil))

        case (.inProgress(let current), .operationCanceled(let id)):
            try requireSame(current, id)
            return at(.canceled)

        case (.inProgress(let current), .userActionRequired(let id, let error)):
            try requireSame(current, id)
            return at(.needsUserAction(id, error))

        case (.needsUserAction(let current, _), .operationCanceled(let id)):
            try requireSame(current, id)
            return at(.canceled)

        case (.needsUserAction(let current, _), .connectionInterrupted(let id)):
            try requireSame(current, id)
            return inspect(operation: id)

        case (.inProgress(let current), .connectionInterrupted(let id)):
            try requireSame(current, id)
            return inspect(operation: id)

        case (.unknownOutcome(let current, _), .connectionInterrupted(let id)):
            try requireSame(current, id)
            return inspect(operation: id)

        case (.unknownOutcome(let current, _), .userRetried), (.unknownOutcome(let current, _), .inspectionRequested):
            // A fresh inspection replaces the outstanding one rather than joining it: the reply
            // to the earlier one describes a state that may already be obsolete, and its token
            // is no longer accepted.
            return inspect(operation: current)

        case (.awaitingInspection, .userRetried), (.awaitingInspection, .inspectionRequested):
            // Reissued rather than suppressed: an inspection whose request was never submitted,
            // whose reply was lost, or that was still outstanding when the app was relaunched
            // would otherwise leave no event that can produce a `reconciled` result.
            return inspect()

        case (.cleanupRequired, .userRetried):
            // The cleanup's result is unknown; inspect rather than clean up blindly again. If
            // it turns out to still be running, `cleanupRunning` resumes monitoring it.
            //
            // `connectionInterrupted` is deliberately not here. A cleanup is an effect, not an
            // operation, so no operation-scoped interruption is about it — the same reason the
            // checkpoint write refuses one that names another operation. Accepting any would
            // let an interruption belonging to an unrelated operation, delivered late, replace
            // this cleanup's token with an inspection and make its own `cleanupFinished` stale.
            // A coordinator that loses contact while a cleanup is pending asks for the
            // inspection by name with `inspectionRequested`, which lands in the same place.
            return inspect()

        case (.inProgress(let current), .inspectionRequested), (.needsUserAction(let current, _), .inspectionRequested):
            // The operation is still live, so its identity is carried through the inspection:
            // an unscoped one would adopt a `stillRunning` naming some other operation, or a
            // `notStarted` that permits a second mutation while this one keeps going.
            return inspect(operation: current)

        case (.recoverableFailure(_, .some(let interrupted)), .inspectionRequested),
             (.recoverableFailure(_, .some(let interrupted)), .userRetried):
            // This failure is a check that could not answer for `interrupted`, so that
            // operation's outcome is exactly as unknown as it was and the replacement
            // inspection stays scoped to it. An unscoped one would adopt whatever identity the
            // next answer happens to name while the first operation may still be mutating
            // (MVP-PLAN.md §3).
            return inspect(operation: interrupted)

        case (_, .inspectionRequested):
            return inspect()

        case (.recoverableFailure, .userRetried), (.canceled, .userRetried):
            return inspect()

        case (.needsUserAction(let current, _), .userActionCompleted):
            // The operation the user was asked to unblock may still be running, so the
            // inspection stays scoped to it rather than accepting whatever it reports.
            return inspect(operation: current)

        case (.unknownOutcome(let interrupted, let inspection), .operationReconciled(let token, let operation, let outcome)):
            try requireOutstanding(inspection, token)
            try requireSame(interrupted, operation)
            switch outcome {
            case .stillRunning(let actualStage):
                // Identity checks above make this inspection authoritative about where the
                // operation is working, so its next checkpoint must be checked at that stage.
                return (ProvisioningState(stage: actualStage, status: .inProgress(operation), issuedEffects: issued), [])
            case .stillNeedsUserAction(let error, let actualStage):
                return (ProvisioningState(stage: actualStage, status: .needsUserAction(operation, error), issuedEffects: issued), [])
            case .quiescent(.stillRunning), .quiescent(.stillNeedsUserAction):
                throw .illegalTransition(status: state.status.caseName, event: event.caseName)
            case .quiescent(let reconciled):
                return try adopt(reconciled, interrupted: interrupted)
            }

        case (.awaitingInspection(let inspection), .reconciled(let token, let outcome)):
            try requireOutstanding(inspection, token)
            // Nothing here knows which operation was in flight, so a reported identity is the
            // only one there is.
            return try adopt(outcome, interrupted: nil)

        case (.awaitingInspection(let inspection), .inspectionFailed(let token, let error)):
            // The inspection could not answer, so nothing is known that was not known before.
            // Keeping the error rather than dropping it is what lets the coordinator show why
            // the check failed and what to do; a retry from a recoverable failure inspects
            // again, so no mutation can be repeated on the strength of a failed check.
            try requireOutstanding(inspection, token)
            return at(.recoverableFailure(error, interrupted: nil))

        case (.unknownOutcome(let interrupted, let inspection), .inspectionFailed(let token, let error)):
            // The same, except that this state knows which operation is unaccounted for. It
            // travels with the error: a failed check settles nothing, so forgetting the
            // operation here would let the retry's inspection adopt a different one while this
            // one may still be mutating.
            try requireOutstanding(inspection, token)
            return at(.recoverableFailure(error, interrupted: interrupted))

        case (.cleanupRequired(_, let cleanup), .cleanupFinished(let token)):
            try requireOutstanding(cleanup, token)
            return at(.notStarted)

        case (.cleanupRequired(_, let cleanup), .cleanupFailed(let token, let error)):
            try requireOutstanding(cleanup, token)
            return at(.recoverableFailure(error, interrupted: nil))

        default:
            throw .illegalTransition(status: state.status.caseName, event: event.caseName)
        }
    }

    private static func requireSame(_ expected: OperationID, _ actual: OperationID) throws(ProvisioningTransitionError) {
        guard expected == actual else { throw .operationMismatch(expected: expected, actual: actual) }
    }

    private static func requireOutstanding(_ expected: EffectToken, _ actual: EffectToken) throws(ProvisioningTransitionError) {
        guard expected == actual else { throw .staleEffect(expected: expected, actual: actual) }
    }
}
