import Foundation

/// Something that happened to a provisioning operation.
public enum ProvisioningEvent: Hashable, Sendable {
    /// The runtime accepted an operation for `stage`.
    case operationStarted(OperationID, stage: ProvisioningStage)
    /// The operation reached its checkpoint. It is not durable until `checkpointPersisted`.
    case checkpointReached(OperationID, Checkpoint)
    /// The journal write for the checkpoint succeeded.
    case checkpointPersisted(Checkpoint)
    /// The journal write for the checkpoint failed. Reality may be ahead of the journal.
    case checkpointPersistenceFailed(GuesthouseError)
    /// The operation failed with an error a retry or repair can address.
    case operationFailed(OperationID, GuesthouseError)
    /// The user canceled the operation and the runtime confirmed it stopped.
    case operationCanceled(OperationID)
    /// The operation cannot continue until the user does something outside the app.
    case userActionRequired(OperationID, GuesthouseError)
    /// The XPC connection dropped while the operation was in flight, or is still down.
    case connectionInterrupted(OperationID)
    /// Actual state was inspected after an interruption or before a retry.
    case reconciled(ReconciledOutcome)
    /// The cleanup requested after a confirmed failure finished.
    case cleanupFinished
    /// The cleanup could not complete.
    case cleanupFailed(GuesthouseError)
    /// The user asked to retry, or to inspect again while the outcome is unknown.
    case userRetried
    /// The user reports the out-of-app step is done.
    case userActionCompleted

    public var caseName: String {
        switch self {
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
        }
    }
}

/// What inspection of the real VM, guest, and journal found.
public enum ReconciledOutcome: Hashable, Sendable {
    /// The stage's checkpoint was in fact reached. It still has to be persisted.
    case completed(Checkpoint)
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
public enum ProvisioningEffect: Hashable, Sendable {
    /// Query the actual state for `stage` before deciding anything else.
    case inspectActualState(ProvisioningStage)
    /// Write the checkpoint to the journal, then send `checkpointPersisted` or
    /// `checkpointPersistenceFailed`.
    case persistCheckpoint(Checkpoint)
    /// Remove the leftovers of a failed attempt, then send `cleanupFinished` or `cleanupFailed`.
    case cleanUp(ProvisioningStage)
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
    /// `ready` has no next stage.
    case alreadyReady
}

extension ProvisioningTransitionError: LocalizedError {
    /// These are programming errors in the coordinator, not user mistakes, but the user still
    /// needs to know the environment's state is uncertain and what to do about it.
    public var userMessage: String {
        switch self {
        case .illegalTransition, .operationMismatch, .checkpointMismatch:
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
/// - An operation starts only from `notStarted`, from `resumable`, or from the previous stage's
///   `completed`. Never from a failure, an unknown outcome, or an unpersisted checkpoint.
/// - Failure, cancellation, interruption, and user action all lead to an inspection before
///   anything re-runs, so a retry can never blindly repeat a step whose real outcome is unknown
///   (MVP-PLAN.md §3, §4, §9). Inspection can be requested again while the outcome is unknown.
/// - A checkpoint counts only once the journal has it (§3: "Persist ... before updating the UI").
public enum ProvisioningReducer {
    public static func reduce(
        _ state: ProvisioningState,
        _ event: ProvisioningEvent
    ) throws(ProvisioningTransitionError) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
        let stage = state.stage
        func at(_ status: StageStatus, _ effects: [ProvisioningEffect] = []) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
            (ProvisioningState(stage: stage, status: status), effects)
        }

        switch (state.status, event) {

        case (.notStarted, .operationStarted(let id, let requested)), (.resumable, .operationStarted(let id, let requested)):
            guard requested == stage else { throw .stageMismatch(expected: stage, actual: requested) }
            return at(.inProgress(id))

        case (.completed, .operationStarted(let id, let requested)):
            guard let next = stage.next else { throw .alreadyReady }
            guard requested == next else { throw .stageMismatch(expected: next, actual: requested) }
            return (ProvisioningState(stage: next, status: .inProgress(id)), [])

        case (.inProgress(let current), .checkpointReached(let id, let checkpoint)):
            try requireSame(current, id)
            guard checkpoint.stage == stage else { throw .stageMismatch(expected: stage, actual: checkpoint.stage) }
            return at(.persistingCheckpoint(checkpoint), [.persistCheckpoint(checkpoint)])

        case (.persistingCheckpoint(let pending), .checkpointPersisted(let persisted)):
            guard pending == persisted else { throw .checkpointMismatch(expected: pending, actual: persisted) }
            return at(.completed(persisted))

        case (.persistingCheckpoint, .checkpointPersistenceFailed):
            return at(.awaitingInspection, [.inspectActualState(stage)])

        case (.inProgress(let current), .operationFailed(let id, let error)):
            try requireSame(current, id)
            return at(.recoverableFailure(error))

        case (.inProgress(let current), .operationCanceled(let id)):
            try requireSame(current, id)
            return at(.canceled)

        case (.inProgress(let current), .userActionRequired(let id, let error)):
            try requireSame(current, id)
            return at(.needsUserAction(error))

        case (.inProgress(let current), .connectionInterrupted(let id)):
            try requireSame(current, id)
            return at(.unknownOutcome(id), [.inspectActualState(stage)])

        case (.unknownOutcome(let current), .connectionInterrupted(let id)):
            try requireSame(current, id)
            return at(.unknownOutcome(id), [.inspectActualState(stage)])

        case (.unknownOutcome, .userRetried), (.awaitingInspection, .userRetried):
            return at(state.status, [.inspectActualState(stage)])

        case (.recoverableFailure, .userRetried), (.canceled, .userRetried):
            return at(.awaitingInspection, [.inspectActualState(stage)])

        case (.needsUserAction, .userActionCompleted):
            return at(.awaitingInspection, [.inspectActualState(stage)])

        case (.unknownOutcome, .reconciled(let outcome)), (.awaitingInspection, .reconciled(let outcome)):
            switch outcome {
            case .completed(let checkpoint):
                guard checkpoint.stage == stage else { throw .stageMismatch(expected: stage, actual: checkpoint.stage) }
                return at(.persistingCheckpoint(checkpoint), [.persistCheckpoint(checkpoint)])
            case .resumable(let evidence):
                return at(.resumable(evidence))
            case .failedNeedsCleanup(let error):
                return at(.cleanupRequired(error), [.cleanUp(stage)])
            case .failed(let error):
                return at(.recoverableFailure(error))
            case .notStarted:
                return at(.notStarted)
            }

        case (.cleanupRequired, .cleanupFinished):
            return at(.notStarted)

        case (.cleanupRequired, .cleanupFailed(let error)):
            return at(.recoverableFailure(error))

        default:
            throw .illegalTransition(status: state.status.caseName, event: event.caseName)
        }
    }

    private static func requireSame(_ expected: OperationID, _ actual: OperationID) throws(ProvisioningTransitionError) {
        guard expected == actual else { throw .operationMismatch(expected: expected, actual: actual) }
    }
}
