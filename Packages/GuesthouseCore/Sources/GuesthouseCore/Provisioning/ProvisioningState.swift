/// Where one environment is in provisioning, and what is happening at that stage.
public struct ProvisioningState: Hashable, Sendable {
    /// Record schema, so the state store can migrate a persisted state after this type changes.
    public private(set) var schemaVersion: SchemaVersion
    /// The checkpoint being worked toward, or the last one completed.
    public private(set) var stage: ProvisioningStage
    public private(set) var status: StageStatus

    /// A status that carries a checkpoint must carry one for `stage`; constructing anything
    /// else is a programming error, and decoding it is rejected. The fields are read-only
    /// afterwards: the only way to change a state is `ProvisioningReducer.reduce`, so the
    /// checkpoint-ordering invariant cannot be broken by assignment.
    public init(stage: ProvisioningStage, status: StageStatus) {
        precondition(Self.isConsistent(stage: stage, status: status), "checkpoint stage does not match \(stage.rawValue)")
        schemaVersion = .current
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
    public var isConsistent: Bool { Self.isConsistent(stage: stage, status: status) }

    static func isConsistent(stage: ProvisioningStage, status: StageStatus) -> Bool {
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
        case schemaVersion, stage, status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        guard version == SchemaVersion.current else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "provisioning state schema \(version) is not \(SchemaVersion.current)")
        }
        schemaVersion = version
        let stage = try container.decode(ProvisioningStage.self, forKey: .stage)
        let status = try container.decode(StageStatus.self, forKey: .status)
        guard Self.isConsistent(stage: stage, status: status) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "checkpoint stage does not match \(stage.rawValue)")
        }
        self.stage = stage
        self.status = status
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(stage, forKey: .stage)
        try container.encode(status, forKey: .status)
    }
}

/// Durable partial work that inspection found after an interruption: a verified partial
/// download, an installation staging area, an unfinished copy. It is neither usable nor
/// discardable; the next operation resumes from it (MVP-PLAN.md §9: "Keep interrupted downloads
/// and installation staging distinct from verified usable artifacts").
public struct ResumeEvidence: Hashable, Sendable {
    public let summary: String
    /// Relative path of the staging area, when there is one.
    public let stagingPath: String?

    /// Both values may derive from guest output or file names, so they are redacted, stripped
    /// of control characters, and bounded at construction; the journal never sees raw text.
    public init(summary: String, stagingPath: String? = nil) {
        self.summary = Self.clean(summary, limit: 200)
        self.stagingPath = stagingPath.map { Self.clean($0, limit: 400) }
    }

    /// The same normalize-then-redact-then-bound pipeline errors use: separators and marks
    /// are dropped before the redactor runs, so a split token is reassembled and removed, and
    /// a URL authority left open by the bound is redacted rather than kept.
    static func clean(_ value: String, limit: Int) -> String {
        GuesthouseError.sanitize(value, limit: limit)
    }
}

extension ResumeEvidence: Codable {
    private enum CodingKeys: String, CodingKey { case summary, stagingPath }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(summary: try container.decode(String.self, forKey: .summary), stagingPath: try container.decodeIfPresent(String.self, forKey: .stagingPath))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(stagingPath, forKey: .stagingPath)
    }
}

/// What is happening at the current stage (MVP-PLAN.md §9: each stage can become canceled,
/// a recoverable failure, or needs user action; plus the interrupted, inspecting, persisting,
/// resumable, and cleanup states that §3, §4, and §9 require).
public enum StageStatus: Codable, Hashable, Sendable {
    /// Nothing has run for this stage. Safe to start.
    case notStarted
    /// A start was requested and the runtime has not yet answered. Reserved synchronously so a
    /// second start cannot slip in while the first request is in flight.
    case startRequested
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
    /// The runtime refused to start the operation before doing anything; the error says why
    /// and what to do. Nothing ran, so a new start may be requested directly.
    case startRejected(GuesthouseError)
    /// The user must do something outside the app (usually at the guest console). The
    /// operation stays identified so the user can cancel it instead of claiming completion.
    case needsUserAction(OperationID, GuesthouseError)
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
        case .startRequested: "startRequested"
        case .startRejected: "startRejected"
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
