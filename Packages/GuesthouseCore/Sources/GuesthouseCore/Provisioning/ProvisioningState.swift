/// Identity of one effect the reducer asked the coordinator to run.
///
/// Every effect carries a token and every callback has to echo it, so a reply from an effect
/// the reducer has since replaced — a re-issued inspection, a second checkpoint write, a
/// cleanup whose connection dropped — names a token that is no longer outstanding and is
/// rejected instead of being taken for the answer to the current one (MVP-PLAN.md §3).
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
    /// Record schema, so the state store can migrate a persisted state after this type changes.
    public private(set) var schemaVersion: SchemaVersion
    /// The checkpoint being worked toward, or the last one completed.
    public private(set) var stage: ProvisioningStage
    public private(set) var status: StageStatus
    /// How many effects this state has issued. The next token is this plus one, and the count
    /// is persisted, so a token is never reused after a relaunch either.
    public private(set) var issuedEffects: UInt64

    /// A status that carries a checkpoint must carry one for `stage`; constructing anything
    /// else is a programming error, and decoding it is rejected. The fields are read-only
    /// afterwards: the only way to change a state is `ProvisioningReducer.reduce`, so the
    /// checkpoint-ordering invariant cannot be broken by assignment.
    public init(stage: ProvisioningStage, status: StageStatus, issuedEffects: UInt64 = 0) {
        precondition(Self.isConsistent(stage: stage, status: status), "checkpoint stage does not match \(stage.rawValue)")
        schemaVersion = .current
        self.stage = stage
        self.status = status
        // The count may never trail the outstanding token, or the next effect would be minted
        // with a token a late callback from the previous one still names.
        self.issuedEffects = max(issuedEffects, status.pendingEffect?.value ?? 0)
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
        guard version == SchemaVersion.current else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "provisioning state schema \(version) is not \(SchemaVersion.current)")
        }
        let stage = try container.decode(ProvisioningStage.self, forKey: .stage)
        let status = try container.decode(StageStatus.self, forKey: .status)
        guard Self.isConsistent(stage: stage, status: status) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "checkpoint stage does not match \(stage.rawValue)")
        }
        self.init(stage: stage, status: status, issuedEffects: try container.decode(UInt64.self, forKey: .issuedEffects))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(stage, forKey: .stage)
        try container.encode(status, forKey: .status)
        try container.encode(issuedEffects, forKey: .issuedEffects)
    }
}

/// Durable partial work that inspection found after an interruption: a verified partial
/// download, an installation staging area, an unfinished copy. It is neither usable nor
/// discardable; the next operation resumes from it (MVP-PLAN.md §9: "Keep interrupted downloads
/// and installation staging distinct from verified usable artifacts").
public struct ResumeEvidence: Hashable, Sendable {
    public let summary: String
    /// Relative path of the staging area, when there is one and it passed validation.
    public let stagingPath: String?

    /// The summary is display text that may derive from guest output, so it is redacted,
    /// stripped of control characters, and bounded at construction; the journal never sees raw
    /// text. The path is not display text — it has to name the same file on the next attempt —
    /// so it is validated and kept exactly, or refused.
    public init(summary: String, stagingPath: String? = nil) {
        self.summary = Self.clean(summary, limit: 200)
        self.stagingPath = stagingPath.flatMap(Self.validStagingPath)
    }

    /// The same normalize-then-redact-then-bound pipeline errors use: separators and marks
    /// are dropped before the redactor runs, so a split token is reassembled and removed, and
    /// a URL authority left open by the bound is redacted rather than kept.
    static func clean(_ value: String, limit: Int) -> String {
        GuesthouseError.sanitize(value, limit: limit)
    }

    static let stagingPathLimit = 1_024

    /// Display sanitizing would drop combining marks and truncate, so a decomposed macOS file
    /// name like `Café.partial` would be journaled as `Cafe.partial` and the next attempt
    /// would look for a file that does not exist (MVP-PLAN.md §9). A path is therefore kept
    /// scalar for scalar or not at all: anything that is not a plain relative guest path, that
    /// carries a control, format, or bidirectional scalar, or that the redactor would rewrite
    /// because it looks like a credential, is refused rather than repaired. Losing the path
    /// costs a resume; storing a changed one would resume against the wrong file.
    static func validStagingPath(_ value: String) -> String? {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= stagingPathLimit else { return nil }
        guard !value.hasPrefix("/"), !value.hasPrefix("~") else { return nil }
        let unsafe = scalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: true
            default: false
            }
        }
        guard !unsafe else { return nil }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        // The redactor sees a probe, not the path: `/` and `.` are word separators to a reader
        // but not always to Unicode word segmentation, so a credential used as a file name with
        // an extension would sit inside one "word" and survive. The path itself is never the
        // redacted text — it is kept whole or refused.
        let probe = String(value.map { $0 == "/" || $0 == "." ? " " : $0 })
        guard Redactor().redact(fieldValue: probe) == probe else { return nil }
        return value
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
    /// `operation` is the operation that reached it, when a live one did, so an interruption
    /// belonging to some other operation cannot abandon this write; reconciliation, which may
    /// have found the checkpoint without a live operation, leaves it empty.
    case persistingCheckpoint(Checkpoint, operation: OperationID?, write: EffectToken)
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

    /// The effect this status is waiting on, when it is waiting on one. Only a callback naming
    /// this token can move the status along.
    public var pendingEffect: EffectToken? {
        switch self {
        case .persistingCheckpoint(_, _, let token), .unknownOutcome(_, let token), .awaitingInspection(let token), .cleanupRequired(_, let token):
            token
        default:
            nil
        }
    }

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
