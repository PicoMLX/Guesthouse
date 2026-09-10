import Foundation

/// Correlated provisioning callbacks (MVP-PLAN.md §§3/9, ADR 0003).
/// Only the trusted coordinator constructs these after validating runtime evidence;
/// they are neither wire-decoding admission nor a generic diagnostic payload.
public enum ProvisioningEvent: Hashable, Sendable {
    /// The coordinator is about to ask the runtime to start `stage`. Reserves the stage before
    /// the asynchronous request so a reentrant start is rejected rather than double-run.
    /// Capture the returned reservation's token before the request, and echo it in every reply.
    case startRequested(stage: ProvisioningStage)
    /// The runtime refused the request before doing anything; nothing durable happened.
    case startRequestRejected(GuesthouseError, request: EffectToken)
    /// The connection dropped while the request was in flight; the runtime may or may not
    /// have accepted it, so actual state must be inspected.
    case startRequestInterrupted(request: EffectToken)
    /// The runtime accepted an operation for `stage`.
    case operationStarted(OperationID, stage: ProvisioningStage, request: EffectToken)
    /// The runtime confirmed this operation reached its checkpoint and can no longer mutate.
    /// A progress line or direct-child exit is insufficient. It is not durable until
    /// `checkpointPersisted`; the coordinator must not advance before that acknowledgement.
    case checkpointReached(OperationID, Checkpoint)
    /// The journal write for the checkpoint succeeded.
    case checkpointPersisted(EffectToken, Checkpoint)
    /// The journal write for the checkpoint failed. Reality may be ahead of the journal.
    case checkpointPersistenceFailed(EffectToken, GuesthouseError)
    /// A failure was reported. This alone does NOT establish mutation quiescence:
    /// retain this operation's identity for inspection even if the error says canceled.
    case operationFailed(OperationID, GuesthouseError)
    /// The runtime confirmed cancellation AND that the whole operation can no longer mutate.
    /// A cancel request, delivered signal or direct-child exit cannot produce this callback.
    case operationCanceled(OperationID)
    /// The operation cannot continue until the user does something outside the app.
    case userActionRequired(OperationID, GuesthouseError)
    /// The XPC connection dropped while the operation was in flight, or is still down.
    case connectionInterrupted(OperationID)
    /// An inspection without a known operation found the stage's actual state. Only accepted
    /// for an unscoped inspection; it cannot settle an identified operation's unknown outcome.
    case reconciled(EffectToken, ReconciledOutcome)
    /// Inspection checked the named operation across all stages. Both the inspection token
    /// and operation identity must match before its active or quiescent outcome is accepted.
    case operationReconciled(EffectToken, OperationID, OperationInspectionOutcome)
    /// The inspection itself could not be carried out — the runtime is still unreachable, or
    /// the guest query failed. The outcome stays unknown; the error says what to do about it.
    case inspectionFailed(EffectToken, GuesthouseError)
    /// The identified cleanup finished and can no longer mutate the staging data.
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

    /// Closed labels keep arbitrary strings and callback payloads out of transition errors.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case startRequested, startRequestRejected, startRequestInterrupted, operationStarted
        case checkpointReached, checkpointPersisted, checkpointPersistenceFailed
        case operationFailed, operationCanceled, userActionRequired, connectionInterrupted
        case reconciled, operationReconciled, inspectionFailed, cleanupFinished, cleanupFailed
        case userRetried, userActionCompleted, inspectionRequested
    }

    public var caseName: String { kind.rawValue }

    public var kind: Kind {
        switch self {
        case .startRequested: .startRequested
        case .startRequestRejected: .startRequestRejected
        case .startRequestInterrupted: .startRequestInterrupted
        case .operationStarted: .operationStarted
        case .checkpointReached: .checkpointReached
        case .checkpointPersisted: .checkpointPersisted
        case .checkpointPersistenceFailed: .checkpointPersistenceFailed
        case .operationFailed: .operationFailed
        case .operationCanceled: .operationCanceled
        case .userActionRequired: .userActionRequired
        case .connectionInterrupted: .connectionInterrupted
        case .reconciled: .reconciled
        case .operationReconciled: .operationReconciled
        case .inspectionFailed: .inspectionFailed
        case .cleanupFinished: .cleanupFinished
        case .cleanupFailed: .cleanupFailed
        case .userRetried: .userRetried
        case .userActionCompleted: .userActionCompleted
        case .inspectionRequested: .inspectionRequested
        }
    }
}

/// What inspection of the real VM, guest, and journal found.
/// Non-active outcomes require confirmed quiescence before they permit another mutation.
/// These values describe runtime evidence; constructing one does not perform the inspection.
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

/// What an inspection established about one identified operation, wherever it is running.
public enum OperationInspectionOutcome: Hashable, Sendable {
    /// The operation is active at this inspected stage, which may differ from the reservation.
    case stillRunning(stage: ProvisioningStage)
    case stillNeedsUserAction(GuesthouseError, stage: ProvisioningStage)
    /// The named operation can no longer mutate anything. Only after establishing that fact
    /// may inspection report the reserved stage's actual state here. An active operation
    /// outcome is contradictory and rejected; an independently tracked cleanup is permitted
    /// because its identity is retained and provisioning stays blocked until it finishes.
    case quiescent(ReconciledOutcome)
}

/// Side effects the coordinator must perform. Descriptions only; nothing runs here.
///
/// Each carries the token the matching callback must echo.
public enum ProvisioningEffect: Hashable, Sendable {
    /// With an operation identity, inspect that operation globally across all stages and send
    /// `operationReconciled`. An active operation cannot be called absent merely because it
    /// is running at a different stage. Once it can no longer mutate, reconcile the reserved
    /// stage and report `quiescent`. Without an identity, inspect the stage and send `reconciled`.
    /// Either inspection may report `inspectionFailed`; uncertainty never authorizes a restart.
    case inspectActualState(ProvisioningStage, EffectToken, operation: OperationID?)
    /// Write the checkpoint to the journal, then send `checkpointPersisted` or
    /// `checkpointPersistenceFailed`.
    case persistCheckpoint(Checkpoint, EffectToken)
    /// Remove the leftovers of a failed attempt, then send `cleanupFinished` or `cleanupFailed`.
    case cleanUp(ProvisioningStage, EffectToken)
}

public enum ProvisioningTransitionError: Error, Hashable, Sendable {
    /// The event is not allowed in the current status.
    case illegalTransition(status: StageStatus.Kind, event: ProvisioningEvent.Kind)
    /// The event names a different operation than the one in flight.
    case operationMismatch(expected: OperationID, actual: OperationID)
    /// The event names a stage that is not the current one or the next one.
    case stageMismatch(expected: ProvisioningStage, actual: ProvisioningStage)
    /// The persisted checkpoint is not the one being persisted.
    case checkpointMismatch(expected: Checkpoint, actual: Checkpoint)
    /// The callback answers an effect that is no longer outstanding.
    case staleEffect(expected: EffectToken, actual: EffectToken)
    /// The reply names an older start request while a different request is still live.
    /// Waiting for the live request, rather than inspecting, keeps its reservation intact.
    case staleStartRequest(expected: EffectToken, actual: EffectToken)
    /// Inspection was asked for while a start request is still in flight. Told apart from a
    /// plain illegal transition because `inspectState` is the one recovery that cannot work
    /// here: offering it would send the same refused event again.
    case inspectionWhileStartRequestLive
    /// No unused persisted effect identity remains. Existing callbacks may still settle;
    /// a new reservation must not wrap the counter or replace the preserved record.
    case effectCounterExhausted
    /// `ready` has no next stage.
    case alreadyReady
}

extension ProvisioningTransitionError: LocalizedError {
    /// Rejected transitions are not user mistakes. Explain the boundary with fixed text,
    /// preserving uncertain state and providing only recovery actions that remain legal.
    public var userMessage: String {
        switch self {
        case .illegalTransition(status: .startRequested, event: _):
            "Guesthouse received a status update while a setup start is reserved. It cannot check the environment until the start request is known to have settled."
        case .illegalTransition, .operationMismatch, .checkpointMismatch, .staleEffect:
            "Guesthouse received a status update that does not match what it was doing. The environment's state is uncertain until it is checked."
        case .stageMismatch:
            "Guesthouse tried to run a setup step out of order. The environment's state is uncertain until it is checked."
        case .inspectionWhileStartRequestLive, .staleStartRequest:
            "Guesthouse is still waiting for its runtime to answer a request to start this setup step, so it cannot check the environment yet."
        case .alreadyReady:
            "Guesthouse has recorded the final setup checkpoint. There is no later setup step."
        case .effectCounterExhausted:
            "Guesthouse cannot reserve another setup effect because this record has no unused effect identities."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .alreadyReady: "Check the environment before relying on its saved readiness."
        case .illegalTransition(status: .startRequested, event: _): "Preserve the start reservation. Wait for the runtime reply or reconnect to recover its state before inspecting."
        case .inspectionWhileStartRequestLive, .staleStartRequest: "Wait for the runtime reply. If contact is lost, preserve the environment and reconnect before inspecting."
        case .effectCounterExhausted: "Cancel the new request and preserve the environment and its state record for recovery. Do not reset its effect counter."
        default: "Preserve the environment and check its state before starting another setup operation."
        }
    }

    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }

    /// The recovery actions the GUI should offer.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        // A kind-only error cannot prove the reservation is inspection-only.
        // Never let an unrelated callback release a potentially live start.
        case .illegalTransition(status: .startRequested, event: _): [.cancel]
        case .inspectionWhileStartRequestLive, .staleStartRequest, .effectCounterExhausted: [.cancel]
        default: [.inspectState, .cancel]
        }
    }
}
