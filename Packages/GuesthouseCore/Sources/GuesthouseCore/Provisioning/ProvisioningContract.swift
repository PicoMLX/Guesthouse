import Foundation

/// Something that happened to a provisioning operation.
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
    /// An inspection without a known operation found the stage's actual state. Only accepted
    /// for an unscoped inspection; it cannot settle an identified operation's unknown outcome.
    case reconciled(EffectToken, ReconciledOutcome)
    /// Inspection checked the named operation across all stages. Both the inspection token
    /// and operation identity must match before its active or quiescent outcome is accepted.
    case operationReconciled(EffectToken, OperationID, OperationInspectionOutcome)
    /// The inspection itself could not be carried out — the runtime is still unreachable, or
    /// the guest query failed. The outcome stays unknown; the error says what to do about it.
    case inspectionFailed(EffectToken, GuesthouseError)
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
        case .operationReconciled: "operationReconciled"
        case .inspectionFailed: "inspectionFailed"
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
    case illegalTransition(status: String, event: String)
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
        case .inspectionWhileStartRequestLive, .staleStartRequest:
            "Guesthouse is still waiting for its runtime to answer a request to start this setup step, so it cannot check the environment yet."
        case .alreadyReady:
            "This development Mac is already fully set up; there is no further setup step to run."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .alreadyReady: "No action is needed."
        case .inspectionWhileStartRequestLive, .staleStartRequest: "Wait for that request to finish. Guesthouse reports a request it lost contact with by itself, and checks the environment then."
        default: "Check the environment before starting anything else. If this repeats, export diagnostics and report it."
        }
    }

    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }

    /// The recovery actions the GUI should offer.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .alreadyReady, .inspectionWhileStartRequestLive, .staleStartRequest: [.cancel]
        default: [.inspectState, .cancel]
        }
    }
}
