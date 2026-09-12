/// Identity of one start request or effect reserved by the reducer.
///
/// Every reservation carries a token and every callback has to echo it. A reply to an earlier
/// inspection, checkpoint write, cleanup, or start request names a token that is no longer
/// outstanding and is rejected instead of settling the current one (MVP-PLAN.md §3).
public struct EffectToken: Hashable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    public var description: String { "effect \(value)" }
}

extension EffectToken: Codable {
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Where one environment is in provisioning, and what is happening at that stage.
public struct ProvisioningState: Hashable, Sendable {
    /// This record's layout version, independent of changes to unrelated persisted formats.
    /// Version 2 replaces raw resume summaries and legacy error payloads with typed facts.
    /// Legacy prototype v1 records are refused, not silently reinterpreted. A future store
    /// must preserve unsupported records and surface recovery rather than overwrite them.
    public static let currentSchema = SchemaVersion(2)!
    /// Record schema, so the state store can migrate a persisted state after this type changes.
    public private(set) var schemaVersion: SchemaVersion
    /// The checkpoint being worked toward, or the last one completed.
    public private(set) var stage: ProvisioningStage
    public private(set) var status: StageStatus
    /// How many start requests and effects this state has issued. Persisted without truncation
    /// so a token is never reused after relaunch. Use `nextEffectToken` instead of adding one.
    public private(set) var issuedEffects: UInt64

    /// The full representable range is valid both in memory and on disk. Exhaustion prevents
    /// a new reservation, not restoration or settlement of an already outstanding effect.
    public static let maximumIssuedEffects = UInt64.max

    /// The next reservation's identity, or nil when no unused identity remains. A coordinator
    /// must refuse new effects on exhaustion and preserve the record for recovery; never wrap,
    /// reset, or reuse a token. Construct the next state with this token before executing it.
    public var nextEffectToken: EffectToken? {
        guard issuedEffects < Self.maximumIssuedEffects else { return nil }
        return EffectToken(issuedEffects + 1)
    }

    /// A status that carries a checkpoint must carry one for `stage`; constructing anything
    /// else is a programming error, and decoding it is rejected. The fields are read-only
    /// afterwards: a transition constructs a new validated state, so the
    /// checkpoint-ordering invariant cannot be broken by assignment.
    public init(stage: ProvisioningStage, status: StageStatus, issuedEffects: UInt64 = 0) {
        precondition(Self.isConsistent(stage: stage, status: status), "checkpoint stage does not match \(stage.rawValue)")
        schemaVersion = Self.currentSchema
        self.stage = stage
        self.status = status
        // The count may never trail the outstanding token, or the next effect would be minted
        // with a token a late callback from the previous one still names.
        self.issuedEffects = max(issuedEffects, status.pendingEffect?.value ?? 0)
    }

    /// A brand-new environment: nothing has run yet.
    public static let initial = ProvisioningState(stage: .first, status: .notStarted)

    /// True only when the final checkpoint has been reached and persisted, and the checkpoint
    /// itself says so. This is saved checkpoint state, NOT current VM/tool readiness; a
    /// coordinator must inspect actual state after relaunch (MVP-PLAN.md §3).
    public var isReady: Bool {
        if stage == .ready, case .completed(let checkpoint) = status, checkpoint.stage == .ready { return true }
        return false
    }

    /// A status that carries a checkpoint must carry one for the outer stage.
    public var isConsistent: Bool { Self.isConsistent(stage: stage, status: status) }

    static func isConsistent(stage: ProvisioningStage, status: StageStatus) -> Bool {
        switch status {
        case .completed(let checkpoint), .persistingCheckpoint(let checkpoint, _, _):
            checkpoint.stage == stage
        default:
            true
        }
    }
}

extension ProvisioningState: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, stage, status, issuedEffects
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        guard version == Self.currentSchema else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "provisioning state schema \(version) is not \(Self.currentSchema)")
        }
        let stage = try container.decode(ProvisioningStage.self, forKey: .stage)
        let status = try container.decode(StageStatus.self, forKey: .status)
        guard Self.isConsistent(stage: stage, status: status) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "checkpoint stage does not match \(stage.rawValue)")
        }
        let issuedEffects = try container.decode(UInt64.self, forKey: .issuedEffects)
        self.init(stage: stage, status: status, issuedEffects: issuedEffects)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(stage, forKey: .stage)
        try container.encode(status, forKey: .status)
        try container.encode(issuedEffects, forKey: .issuedEffects)
    }
}

/// What is happening at the current stage (MVP-PLAN.md §9: each stage can become canceled,
/// a recoverable failure, or needs user action; plus the interrupted, inspecting, persisting,
/// resumable, and cleanup states that §3, §4, and §9 require).
public enum StageStatus: Codable, Hashable, Sendable {
    /// Nothing has run for this stage. Safe to start.
    case notStarted
    /// A start was requested and the runtime has not yet answered. Reserved synchronously so a
    /// second start cannot slip in while the first request is in flight. `resuming` is the
    /// durable partial work the reservation was made from, when there was any: the artifact
    /// outlives a refused request, and forgetting it here would leave the next start with no
    /// staging path to continue from (MVP-PLAN.md §9).
    /// `request` is minted by the reducer and must be captured before asking the runtime;
    /// every acceptance, rejection, and interruption echoes that same token. It is optional
    /// for an inspection-only reservation whose acceptance identity is unavailable.
    /// A restored tokenless reservation accepts no callbacks and must be inspected first.
    case startRequested(request: EffectToken?, resuming: ResumeEvidence?)
    /// An operation is running.
    case inProgress(OperationID)
    /// The checkpoint was reached but is not yet durable. Nothing may advance until it is.
    /// `operation` is the operation that reached it, when a live one did, so an interruption
    /// belonging to some other operation cannot abandon this write; reconciliation, which may
    /// have found the checkpoint without a live operation, leaves it empty.
    case persistingCheckpoint(Checkpoint, operation: OperationID?, write: EffectToken)
    /// The stage's checkpoint was reached and journaled.
    case completed(Checkpoint)
    /// The user canceled. Retrying inspects actual state first.
    case canceled
    /// The operation failed in a way a retry or repair can address. Retrying inspects first.
    /// `interrupted` is the operation whose outcome this failure did not settle — an inspection
    /// that could not answer leaves one — so the retry's inspection stays scoped to it. A
    /// failure the runtime reported for an operation it had finished with settles that
    /// operation and leaves it empty.
    case recoverableFailure(GuesthouseError, interrupted: OperationID?)
    /// The runtime refused to start the operation before doing anything; the error says why
    /// and what to do. Nothing ran, so a new start may be requested directly, and it carries
    /// the same resume evidence the refused request did.
    case startRejected(GuesthouseError, resuming: ResumeEvidence?)
    /// The user must do something outside the app (usually at the guest console). The
    /// operation stays identified so the user can cancel it instead of claiming completion.
    case needsUserAction(OperationID, GuesthouseError)
    /// Contact with the runtime was lost mid-operation. The outcome is unknown until the
    /// inspection this is waiting on reports back.
    case unknownOutcome(OperationID, inspection: EffectToken)
    /// Actual state is being inspected before anything is re-run.
    case awaitingInspection(EffectToken)
    /// Inspection found durable partial work. Starting the stage resumes from it.
    case resumable(ResumeEvidence)
    /// Inspection found a failed attempt that left state behind. It must be cleaned before
    /// the stage can start again; `cleanup` identifies the cleanup that is running.
    case cleanupRequired(GuesthouseError, cleanup: EffectToken)

    /// The start request or effect this status is waiting on. Only a callback naming
    /// this token can move the status along.
    public var pendingEffect: EffectToken? {
        switch self {
        case .startRequested(let token, _):
            token
        case .persistingCheckpoint(_, _, let token), .unknownOutcome(_, let token), .awaitingInspection(let token), .cleanupRequired(_, let token):
            token
        default:
            nil
        }
    }

    /// A fixed label for tests and presentation; never serialize this whole status as a log.
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
