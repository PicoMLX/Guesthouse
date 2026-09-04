import Foundation

/// Something that happened to a provisioning operation.
public enum ProvisioningEvent: Hashable, Sendable {
    /// The coordinator is about to ask the runtime to start `stage`. Reserves the stage before
    /// the asynchronous request so a reentrant start is rejected rather than double-run.
    case startRequested(stage: ProvisioningStage)
    /// The runtime refused the request before doing anything; nothing durable happened.
    case startRequestRejected(GuesthouseError)
    /// The connection dropped while the request was in flight; the runtime may or may not
    /// have accepted it, so actual state must be inspected.
    case startRequestInterrupted
    /// The runtime accepted an operation for `stage`.
    case operationStarted(OperationID, stage: ProvisioningStage)
    /// The operation reached its checkpoint. It is not durable until `checkpointPersisted`.
    case checkpointReached(OperationID, Checkpoint)
    /// The journal write for the checkpoint succeeded.
    case checkpointPersisted(EffectToken, Checkpoint)
    /// The journal write for the checkpoint failed. Reality may be ahead of the journal.
    case checkpointPersistenceFailed(EffectToken, GuesthouseError)
    /// The operation failed with an error a retry or repair can address.
    case operationFailed(OperationID, GuesthouseError)
    /// The user canceled the operation and the runtime confirmed it stopped.
    case operationCanceled(OperationID)
    /// The operation cannot continue until the user does something outside the app.
    case userActionRequired(OperationID, GuesthouseError)
    /// The XPC connection dropped while the operation was in flight, or is still down.
    case connectionInterrupted(OperationID)
    /// Actual state was inspected after an interruption or before a retry. Only accepted for
    /// the inspection that is currently outstanding.
    case reconciled(EffectToken, ReconciledOutcome)
    /// The cleanup requested after a confirmed failure finished.
    case cleanupFinished(EffectToken)
    /// The cleanup could not complete.
    case cleanupFailed(EffectToken, GuesthouseError)
    /// The user asked to retry, or to inspect again while the outcome is unknown.
    case userRetried
    /// The user reports the out-of-app step is done.
    case userActionCompleted
    /// The coordinator (or the user through a recovery action) asks for the actual state to be
    /// inspected from any status where the reducer cannot know what happened: a stale or
    /// mismatched callback, a lost effect, a relaunch. Illegal only while a start request is
    /// still live, because inspecting then would release a reservation the runtime may still
    /// turn into a mutation.
    case inspectionRequested

    public var caseName: String {
        switch self {
        case .startRequested: "startRequested"
        case .startRequestRejected: "startRequestRejected"
        case .startRequestInterrupted: "startRequestInterrupted"
        case .operationStarted: "operationStarted"
        case .checkpointReached: "checkpointReached"
        case .checkpointPersisted: "checkpointPersisted"
        case .checkpointPersistenceFailed: "checkpointPersistenceFailed"
        case .operationFailed: "operationFailed"
        case .operationCanceled: "operationCanceled"
        case .userActionRequired: "userActionRequired"
        case .connectionInterrupted: "connectionInterrupted"
        case .reconciled: "reconciled"
        case .cleanupFinished: "cleanupFinished"
        case .cleanupFailed: "cleanupFailed"
        case .userRetried: "userRetried"
        case .userActionCompleted: "userActionCompleted"
        case .inspectionRequested: "inspectionRequested"
        }
    }
}

/// What inspection of the real VM, guest, and journal found.
public enum ReconciledOutcome: Hashable, Sendable {
    /// A checkpoint was in fact reached. It still has to be persisted. It may name a later
    /// stage than the saved state does: the runtime can have journaled or finished a further
    /// step before the crash that left the state behind.
    case completed(Checkpoint)
    /// The runtime still has the operation in flight (the connection came back while it was
    /// running). Monitoring resumes under the same identity; nothing is restarted.
    case stillRunning(OperationID)
    /// The operation is still paused for the out-of-app step it was paused for when contact
    /// was lost. The prompt and its recovery actions are restored rather than being flattened
    /// into "running" or offered for a restart.
    case stillNeedsUserAction(OperationID, GuesthouseError)
    /// The cleanup that was running when contact was lost is still running. The coordinator
    /// names the cleanup it is still waiting on, so monitoring resumes instead of a second
    /// cleanup being launched over the first one's staging data.
    case cleanupRunning(EffectToken, GuesthouseError)
    /// Durable partial work exists; the next start resumes from it.
    case resumable(ResumeEvidence)
    /// The attempt failed and left state that must be removed before starting again.
    case failedNeedsCleanup(GuesthouseError)
    /// The attempt failed for a reason the user must address first (for example a changed
    /// host key). The error's recovery actions say how; a plain retry would find it again.
    case failed(GuesthouseError)
    /// Nothing durable happened; the stage can be started again safely.
    case notStarted
}

/// Side effects the coordinator must perform. Descriptions only; nothing runs here.
///
/// Each carries the token the matching callback must echo.
public enum ProvisioningEffect: Hashable, Sendable {
    /// Query the actual state for `stage`, then send `reconciled`, before deciding anything else.
    case inspectActualState(ProvisioningStage, EffectToken)
    /// Write the checkpoint to the journal, then send `checkpointPersisted` or
    /// `checkpointPersistenceFailed`.
    case persistCheckpoint(Checkpoint, EffectToken)
    /// Remove the leftovers of a failed attempt, then send `cleanupFinished` or `cleanupFailed`.
    case cleanUp(ProvisioningStage, EffectToken)
}

public enum ProvisioningTransitionError: Error, Hashable, Sendable {
    /// The event is not allowed in the current status.
    case illegalTransition(status: String, event: String)
    /// The event names a different operation than the one in flight.
    case operationMismatch(expected: OperationID, actual: OperationID)
    /// The event names a stage that is not the current one or the next one.
    case stageMismatch(expected: ProvisioningStage, actual: ProvisioningStage)
    /// The persisted checkpoint is not the one being persisted.
    case checkpointMismatch(expected: Checkpoint, actual: Checkpoint)
    /// The callback answers an effect that is no longer outstanding.
    case staleEffect(expected: EffectToken, actual: EffectToken)
    /// `ready` has no next stage.
    case alreadyReady
}

extension ProvisioningTransitionError: LocalizedError {
    /// These are programming errors in the coordinator, not user mistakes, but the user still
    /// needs to know the environment's state is uncertain and what to do about it.
    public var userMessage: String {
        switch self {
        case .illegalTransition, .operationMismatch, .checkpointMismatch, .staleEffect:
            "Guesthouse received a status update that does not match what it was doing. The environment's state is uncertain until it is checked."
        case .stageMismatch:
            "Guesthouse tried to run a setup step out of order. The environment's state is uncertain until it is checked."
        case .alreadyReady:
            "This development Mac is already fully set up; there is no further setup step to run."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .alreadyReady: "No action is needed."
        default: "Check the environment before starting anything else. If this repeats, export diagnostics and report it."
        }
    }

    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }

    /// The recovery actions the GUI should offer.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .alreadyReady: [.cancel]
        default: [.inspectState, .cancel]
        }
    }
}

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
/// - Every effect is issued with a token and only the callback naming the outstanding token is
///   accepted, so a lost effect can be reissued and a late reply to a replaced one is rejected.
/// - A checkpoint counts only once the journal has it (§3: "Persist ... before updating the UI").
public enum ProvisioningReducer: Sendable {
    public static func reduce(
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
        func inspect(_ status: (EffectToken) -> StageStatus) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
            let token = mint()
            return at(status(token), [.inspectActualState(stage, token)])
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
                return at(.recoverableFailure(error))
            case .notStarted:
                return at(.notStarted)
            }
        }

        switch (state.status, event) {

        case (.notStarted, .startRequested(let requested)), (.resumable, .startRequested(let requested)), (.startRejected, .startRequested(let requested)):
            guard requested == stage else { throw .stageMismatch(expected: stage, actual: requested) }
            return at(.startRequested)

        case (.completed, .startRequested(let requested)):
            guard let next = stage.next else { throw .alreadyReady }
            guard requested == next else { throw .stageMismatch(expected: next, actual: requested) }
            return (ProvisioningState(stage: next, status: .startRequested, issuedEffects: issued), [])

        case (.startRequested, .operationStarted(let id, let requested)):
            guard requested == stage else { throw .stageMismatch(expected: stage, actual: requested) }
            return at(.inProgress(id))

        case (.startRequested, .startRequestRejected(let error)):
            return at(.startRejected(error))

        case (.startRequested, .startRequestInterrupted):
            return inspect(StageStatus.awaitingInspection)

        case (.startRequested, .inspectionRequested):
            // The reservation stays held: the request is still live, so the runtime may still
            // accept it, and an inspection that reported `notStarted` would let a second start
            // race the first. A dropped connection is reported as `startRequestInterrupted`,
            // which ends the request and does inspect.
            throw .illegalTransition(status: state.status.caseName, event: event.caseName)

        case (.inProgress(let current), .checkpointReached(let id, let checkpoint)):
            try requireSame(current, id)
            guard checkpoint.stage == stage else { throw .stageMismatch(expected: stage, actual: checkpoint.stage) }
            let write = mint()
            return at(.persistingCheckpoint(checkpoint, operation: current, write: write), [.persistCheckpoint(checkpoint, write)])

        case (.persistingCheckpoint(let pending, _, let write), .checkpointPersisted(let token, let persisted)):
            try requireOutstanding(write, token)
            guard pending == persisted else { throw .checkpointMismatch(expected: pending, actual: persisted) }
            return at(.completed(persisted))

        case (.persistingCheckpoint(_, _, let write), .checkpointPersistenceFailed(let token, let error)):
            // Reality is ahead of the journal. The failure is shown with its recovery actions;
            // the user's retry inspects, finds the checkpoint reached, and persists it again.
            try requireOutstanding(write, token)
            return at(.recoverableFailure(error))

        case (.persistingCheckpoint(_, let writer, _), .connectionInterrupted(let id)):
            // The write's result is unknown; the journal is inspected before anything else.
            // An interruption belonging to another operation says nothing about this write.
            if let writer { try requireSame(writer, id) }
            return inspect(StageStatus.awaitingInspection)

        case (.persistingCheckpoint, .userRetried):
            return inspect(StageStatus.awaitingInspection)

        case (.inProgress(let current), .operationFailed(let id, let error)):
            try requireSame(current, id)
            return at(.recoverableFailure(error))

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
            return inspect { .unknownOutcome(id, inspection: $0) }

        case (.inProgress(let current), .connectionInterrupted(let id)):
            try requireSame(current, id)
            return inspect { .unknownOutcome(id, inspection: $0) }

        case (.unknownOutcome(let current, _), .connectionInterrupted(let id)):
            try requireSame(current, id)
            return inspect { .unknownOutcome(id, inspection: $0) }

        case (.unknownOutcome(let current, _), .userRetried), (.unknownOutcome(let current, _), .inspectionRequested):
            // A fresh inspection replaces the outstanding one rather than joining it: the reply
            // to the earlier one describes a state that may already be obsolete, and its token
            // is no longer accepted.
            return inspect { .unknownOutcome(current, inspection: $0) }

        case (.awaitingInspection, .userRetried), (.awaitingInspection, .inspectionRequested):
            // Reissued rather than suppressed: an inspection whose request was never submitted,
            // whose reply was lost, or that was still outstanding when the app was relaunched
            // would otherwise leave no event that can produce a `reconciled` result.
            return inspect(StageStatus.awaitingInspection)

        case (.cleanupRequired, .connectionInterrupted), (.cleanupRequired, .userRetried):
            // The cleanup's result is unknown; inspect rather than clean up blindly again. If
            // it turns out to still be running, `cleanupRunning` resumes monitoring it.
            return inspect(StageStatus.awaitingInspection)

        case (_, .inspectionRequested):
            return inspect(StageStatus.awaitingInspection)

        case (.recoverableFailure, .userRetried), (.canceled, .userRetried):
            return inspect(StageStatus.awaitingInspection)

        case (.needsUserAction, .userActionCompleted):
            return inspect(StageStatus.awaitingInspection)

        case (.unknownOutcome(let interrupted, let inspection), .reconciled(let token, let outcome)):
            try requireOutstanding(inspection, token)
            return try adopt(outcome, interrupted: interrupted)

        case (.awaitingInspection(let inspection), .reconciled(let token, let outcome)):
            try requireOutstanding(inspection, token)
            // Nothing here knows which operation was in flight, so a reported identity is the
            // only one there is.
            return try adopt(outcome, interrupted: nil)

        case (.cleanupRequired(_, let cleanup), .cleanupFinished(let token)):
            try requireOutstanding(cleanup, token)
            return at(.notStarted)

        case (.cleanupRequired(_, let cleanup), .cleanupFailed(let token, let error)):
            try requireOutstanding(cleanup, token)
            return at(.recoverableFailure(error))

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
