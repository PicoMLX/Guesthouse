/// Where one environment is in provisioning, and what is happening at that stage.
public struct ProvisioningState: Codable, Hashable, Sendable {
    /// The checkpoint being worked toward, or the last one completed.
    public var stage: ProvisioningStage
    public var status: StageStatus

    public init(stage: ProvisioningStage, status: StageStatus) {
        self.stage = stage
        self.status = status
    }

    /// A brand-new environment: nothing has run yet.
    public static let initial = ProvisioningState(stage: .first, status: .notStarted)

    /// True only when the final checkpoint has been reached.
    public var isReady: Bool {
        if stage == .ready, case .completed = status { return true }
        return false
    }
}

/// What is happening at the current stage (MVP-PLAN.md §9: each stage can become canceled,
/// a recoverable failure, or needs user action; plus the interrupted and inspecting states
/// that §3 and §4 require for unknown outcomes).
public enum StageStatus: Codable, Hashable, Sendable {
    /// Nothing has run for this stage. Safe to start.
    case notStarted
    /// An operation is running.
    case inProgress(OperationID)
    /// The stage's checkpoint was reached.
    case completed(Checkpoint)
    /// The user canceled. Retrying inspects actual state first.
    case canceled
    /// The operation failed in a way a retry or repair can address. Retrying inspects first.
    case recoverableFailure(GuesthouseError)
    /// The user must do something outside the app (usually at the guest console).
    case needsUserAction(GuesthouseError)
    /// Contact with the runtime was lost mid-operation. The outcome is unknown until reconciled.
    case unknownOutcome(OperationID)
    /// Actual state is being inspected before anything is re-run.
    case awaitingInspection

    /// A short label for logs and tests.
    public var caseName: String {
        switch self {
        case .notStarted: "notStarted"
        case .inProgress: "inProgress"
        case .completed: "completed"
        case .canceled: "canceled"
        case .recoverableFailure: "recoverableFailure"
        case .needsUserAction: "needsUserAction"
        case .unknownOutcome: "unknownOutcome"
        case .awaitingInspection: "awaitingInspection"
        }
    }
}
