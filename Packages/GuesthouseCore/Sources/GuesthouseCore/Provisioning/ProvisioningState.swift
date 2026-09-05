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
    /// Record schema, so the state store can migrate a persisted state after this type changes.
    public private(set) var schemaVersion: SchemaVersion
    /// The checkpoint being worked toward, or the last one completed.
    public private(set) var stage: ProvisioningStage
    public private(set) var status: StageStatus
    /// How many start requests and effects this state has issued. The next token is this plus
    /// one, and the count is persisted, so a token is never reused after a relaunch either.
    public private(set) var issuedEffects: UInt64

    /// A status that carries a checkpoint must carry one for `stage`; constructing anything
    /// else is a programming error, and decoding it is rejected. The fields are read-only
    /// afterwards: the only way to change a state is `ProvisioningReducer.reduce`, so the
    /// checkpoint-ordering invariant cannot be broken by assignment.
    /// The largest effect counter a *persisted* state may carry. A transition mints at most one
    /// token, so reaching this would take more transitions than a process can perform: a higher
    /// count is a corrupt or hostile record rather than a state this package wrote, and it is
    /// refused where it is read. A state that has been minting since it was read may stand above
    /// the ceiling without being wrong, which is what the other half of the range is for — no
    /// sequence of transitions can consume that headroom, so the next mint always has a token.
    public static let maximumIssuedEffects = UInt64.max / 2

    public init(stage: ProvisioningStage, status: StageStatus, issuedEffects: UInt64 = 0) {
        precondition(Self.isConsistent(stage: stage, status: status), "checkpoint stage does not match \(stage.rawValue)")
        schemaVersion = .current
        self.stage = stage
        self.status = status
        // The count may never trail the outstanding token, or the next effect would be minted
        // with a token a late callback from the previous one still names.
        let count = max(issuedEffects, status.pendingEffect?.value ?? 0)
        // Deliberately not `maximumIssuedEffects`: that ceiling is a rule about records read
        // from disk, and a state decoded at the ceiling mints its next token one above it.
        // Holding this initializer to the same number would trap on that first transition —
        // the very crash the ceiling exists to prevent — so what is refused here is a count
        // with no token left above it at all, which the ceiling's headroom puts out of reach.
        precondition(count < UInt64.max, "effect counter \(count) leaves no token to mint")
        self.issuedEffects = count
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
        let issuedEffects = try container.decode(UInt64.self, forKey: .issuedEffects)
        guard max(issuedEffects, status.pendingEffect?.value ?? 0) <= Self.maximumIssuedEffects else {
            throw DecodingError.dataCorruptedError(forKey: .issuedEffects, in: container, debugDescription: "effect counter is beyond \(Self.maximumIssuedEffects)")
        }
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
        // Both probes reassemble credentials split by marks or spaces. One preserves the dots
        // and slashes needed by JWT and URL rules; the other treats them as word boundaries so
        // a credential used as a file name stays visible. Combining both transformations in a
        // single reading would reassemble a split JWT while destroying its required dots.
        // These are detection readings only: an accepted path is always stored unchanged.
        var normalizedScalars = String.UnicodeScalarView()
        var probeScalars = String.UnicodeScalarView()
        for scalar in scalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .spaceSeparator:
                continue
            default:
                normalizedScalars.append(scalar)
            }
            probeScalars.append(scalar == "/" || scalar == "." ? " " : scalar)
        }
        let normalized = String(normalizedScalars)
        guard Redactor().redact(fieldValue: normalized) == normalized else { return nil }
        let probe = String(probeScalars)
        guard Redactor().redact(fieldValue: probe) == probe else { return nil }
        // The original reading also retains spacing and marks that may delimit a credential.
        return Redactor().redact(fieldValue: value) == value ? value : nil
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
    /// second start cannot slip in while the first request is in flight. `resuming` is the
    /// durable partial work the reservation was made from, when there was any: the artifact
    /// outlives a refused request, and forgetting it here would leave the next start with no
    /// staging path to continue from (MVP-PLAN.md §9).
    /// `request` is minted by the reducer and must be captured before asking the runtime;
    /// every acceptance, rejection, and interruption echoes that same token. It is optional
    /// only so older records without a token decode without losing their resume evidence.
    /// Such a restored reservation accepts no callbacks and must be inspected before starting.
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
