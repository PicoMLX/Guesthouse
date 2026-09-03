/// Where one environment is in provisioning, and what is happening at that stage.
public struct ProvisioningState: Hashable, Sendable {
    /// The checkpoint being worked toward, or the last one completed.
    public var stage: ProvisioningStage
    public var status: StageStatus

    public init(stage: ProvisioningStage, status: StageStatus) {
        self.stage = stage
        self.status = status
    }

    /// A brand-new environment: nothing has run yet.
    public static let initial = ProvisioningState(stage: .first, status: .notStarted)

    /// True only when the final checkpoint has been reached and persisted, and the checkpoint
    /// itself says so. A `completed` status whose checkpoint names another stage is not proof.
    public var isReady: Bool {
        if stage == .ready, case .completed(let checkpoint) = status, checkpoint.stage == .ready { return true }
        return false
    }

    /// A status that carries a checkpoint must carry one for the outer stage.
    public var isConsistent: Bool {
        switch status {
        case .completed(let checkpoint), .persistingCheckpoint(let checkpoint):
            checkpoint.stage == stage
        default:
            true
        }
    }
}

extension ProvisioningState: Codable {
    private enum CodingKeys: String, CodingKey {
        case stage, status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decode(ProvisioningStage.self, forKey: .stage)
        status = try container.decode(StageStatus.self, forKey: .status)
        guard isConsistent else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "checkpoint stage does not match \(stage.rawValue)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stage, forKey: .stage)
        try container.encode(status, forKey: .status)
    }
}

/// Durable partial work that inspection found after an interruption: a verified partial
/// download, an installation staging area, an unfinished copy. It is neither usable nor
/// discardable; the next operation resumes from it (MVP-PLAN.md §9: "Keep interrupted downloads
/// and installation staging distinct from verified usable artifacts").
public struct ResumeEvidence: Codable, Hashable, Sendable {
    public var summary: String
    /// Relative path of the staging area, when there is one.
    public var stagingPath: String?

    public init(summary: String, stagingPath: String? = nil) {
        self.summary = summary
        self.stagingPath = stagingPath
    }
}

/// What is happening at the current stage (MVP-PLAN.md §9: each stage can become canceled,
/// a recoverable failure, or needs user action; plus the interrupted, inspecting, persisting,
/// resumable, and cleanup states that §3, §4, and §9 require).
public enum StageStatus: Codable, Hashable, Sendable {
    /// Nothing has run for this stage. Safe to start.
    case notStarted
    /// An operation is running.
    case inProgress(OperationID)
    /// The checkpoint was reached but is not yet durable. Nothing may advance until it is.
    case persistingCheckpoint(Checkpoint)
    /// The stage's checkpoint was reached and journaled.
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
    /// Inspection found durable partial work. Starting the stage resumes from it.
    case resumable(ResumeEvidence)
    /// Inspection found a failed attempt that left state behind. It must be cleaned before
    /// the stage can start again.
    case cleanupRequired(GuesthouseError)

    /// A short label for logs and tests.
    public var caseName: String {
        switch self {
        case .notStarted: "notStarted"
        case .inProgress: "inProgress"
        case .persistingCheckpoint: "persistingCheckpoint"
        case .completed: "completed"
        case .canceled: "canceled"
        case .recoverableFailure: "recoverableFailure"
        case .needsUserAction: "needsUserAction"
        case .unknownOutcome: "unknownOutcome"
        case .awaitingInspection: "awaitingInspection"
        case .resumable: "resumable"
        case .cleanupRequired: "cleanupRequired"
        }
    }
}
