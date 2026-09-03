/// Something that happened to a provisioning operation.
public enum ProvisioningEvent: Hashable, Sendable {
    /// The runtime accepted an operation for `stage`.
    case operationStarted(OperationID, stage: ProvisioningStage)
    /// The operation reached its checkpoint.
    case checkpointReached(OperationID, Checkpoint)
    /// The operation failed with an error a retry or repair can address.
    case operationFailed(OperationID, GuesthouseError)
    /// The user canceled the operation and the runtime confirmed it stopped.
    case operationCanceled(OperationID)
    /// The operation cannot continue until the user does something outside the app.
    case userActionRequired(OperationID, GuesthouseError)
    /// The XPC connection dropped while the operation was in flight.
    case connectionInterrupted(OperationID)
    /// Actual state was inspected after an interruption or before a retry.
    case reconciled(ReconciledOutcome)
    /// The user asked to retry after a failure or cancellation.
    case userRetried
    /// The user reports the out-of-app step is done.
    case userActionCompleted

    public var caseName: String {
        switch self {
        case .operationStarted: "operationStarted"
        case .checkpointReached: "checkpointReached"
        case .operationFailed: "operationFailed"
        case .operationCanceled: "operationCanceled"
        case .userActionRequired: "userActionRequired"
        case .connectionInterrupted: "connectionInterrupted"
        case .reconciled: "reconciled"
        case .userRetried: "userRetried"
        case .userActionCompleted: "userActionCompleted"
        }
    }
}

/// What inspection of the real VM, guest, and journal found.
public enum ReconciledOutcome: Hashable, Sendable {
    /// The stage's checkpoint was in fact reached.
    case completed(Checkpoint)
    /// The stage in fact failed.
    case failed(GuesthouseError)
    /// Nothing durable happened; the stage can be started again safely.
    case notStarted
}

/// Side effects the coordinator must perform. Descriptions only; nothing runs here.
public enum ProvisioningEffect: Hashable, Sendable {
    /// Query the actual state for `stage` before deciding anything else.
    case inspectActualState(ProvisioningStage)
    /// Write the checkpoint to the journal before showing it in the UI.
    case persistCheckpoint(Checkpoint)
}

public enum ProvisioningTransitionError: Error, Hashable, Sendable {
    /// The event is not allowed in the current status.
    case illegalTransition(status: String, event: String)
    /// The event names a different operation than the one in flight.
    case operationMismatch(expected: OperationID, actual: OperationID)
    /// The event names a stage that is not the current one or the next one.
    case stageMismatch(expected: ProvisioningStage, actual: ProvisioningStage)
    /// `ready` has no next stage.
    case alreadyReady
}

/// Pure transition function for `ProvisioningState`.
///
/// The one rule that everything else follows from: an operation is only ever started from
/// `notStarted` or from `completed` at the previous stage. After a failure, cancellation,
/// interruption, or user action there is always an inspection first, so a retry can never
/// blindly re-run a step whose real outcome is unknown (MVP-PLAN.md §3, §4, §9).
public enum ProvisioningReducer {
    public static func reduce(
        _ state: ProvisioningState,
        _ event: ProvisioningEvent
    ) throws(ProvisioningTransitionError) -> (state: ProvisioningState, effects: [ProvisioningEffect]) {
        switch (state.status, event) {

        case (.notStarted, .operationStarted(let id, let stage)):
            guard stage == state.stage else { throw .stageMismatch(expected: state.stage, actual: stage) }
            return (ProvisioningState(stage: stage, status: .inProgress(id)), [])

        case (.completed, .operationStarted(let id, let stage)):
            guard let next = state.stage.next else { throw .alreadyReady }
            guard stage == next else { throw .stageMismatch(expected: next, actual: stage) }
            return (ProvisioningState(stage: stage, status: .inProgress(id)), [])

        case (.inProgress(let current), .checkpointReached(let id, let checkpoint)):
            try requireSame(current, id)
            guard checkpoint.stage == state.stage else {
                throw .stageMismatch(expected: state.stage, actual: checkpoint.stage)
            }
            return (ProvisioningState(stage: state.stage, status: .completed(checkpoint)), [.persistCheckpoint(checkpoint)])

        case (.inProgress(let current), .operationFailed(let id, let error)):
            try requireSame(current, id)
            return (ProvisioningState(stage: state.stage, status: .recoverableFailure(error)), [])

        case (.inProgress(let current), .operationCanceled(let id)):
            try requireSame(current, id)
            return (ProvisioningState(stage: state.stage, status: .canceled), [])

        case (.inProgress(let current), .userActionRequired(let id, let error)):
            try requireSame(current, id)
            return (ProvisioningState(stage: state.stage, status: .needsUserAction(error)), [])

        case (.inProgress(let current), .connectionInterrupted(let id)):
            try requireSame(current, id)
            return (ProvisioningState(stage: state.stage, status: .unknownOutcome(id)), [.inspectActualState(state.stage)])

        case (.recoverableFailure, .userRetried), (.canceled, .userRetried):
            return (ProvisioningState(stage: state.stage, status: .awaitingInspection), [.inspectActualState(state.stage)])

        case (.needsUserAction, .userActionCompleted):
            return (ProvisioningState(stage: state.stage, status: .awaitingInspection), [.inspectActualState(state.stage)])

        case (.unknownOutcome, .reconciled(let outcome)), (.awaitingInspection, .reconciled(let outcome)):
            switch outcome {
            case .completed(let checkpoint):
                guard checkpoint.stage == state.stage else {
                    throw .stageMismatch(expected: state.stage, actual: checkpoint.stage)
                }
                return (ProvisioningState(stage: state.stage, status: .completed(checkpoint)), [.persistCheckpoint(checkpoint)])
            case .failed(let error):
                return (ProvisioningState(stage: state.stage, status: .recoverableFailure(error)), [])
            case .notStarted:
                return (ProvisioningState(stage: state.stage, status: .notStarted), [])
            }

        default:
            throw .illegalTransition(status: state.status.caseName, event: event.caseName)
        }
    }

    private static func requireSame(_ expected: OperationID, _ actual: OperationID) throws(ProvisioningTransitionError) {
        guard expected == actual else { throw .operationMismatch(expected: expected, actual: actual) }
    }
}
