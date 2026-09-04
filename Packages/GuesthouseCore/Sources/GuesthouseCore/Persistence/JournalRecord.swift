import Foundation

/// The closed set of operations the journal can record. A misspelled or unsupported kind is a
/// compile error, so replay always knows which state inspection an in-flight record needs.
///
/// Two of them are recorded with the detail that inspection needs: the stage a provisioning
/// attempt was working toward, and which of the five targeted repairs was running. Without
/// them an operation interrupted before its first checkpoint would only say "provision" or
/// "repair", and the snapshot's last completed stage is not proof of what had started.
public enum JournalOperation: Codable, Hashable, Sendable, CaseIterable {
    case startEnvironment
    case stopEnvironment
    case provision(stage: ProvisioningStage)
    case importXcode
    case deleteEnvironment
    case exportWork
    case repair(kind: RepairKind)

    public static var allCases: [JournalOperation] {
        [.startEnvironment, .stopEnvironment, .importXcode, .deleteEnvironment, .exportWork]
            + ProvisioningStage.allCases.map { .provision(stage: $0) }
            + RepairKind.allCases.map { .repair(kind: $0) }
    }
}

/// One line of the append-only operation journal.
///
/// The journal is written before the UI learns about a change and replayed on launch to find
/// operations that never reported a result (MVP-PLAN.md §3: "Persist operation identifiers
/// and completed checkpoints before updating the UI"). Every line carries its own format
/// version so a later format can be migrated or refused per record instead of failing the
/// whole journal.
public struct JournalRecord: Codable, Hashable, Sendable {
    /// The record format this build writes and the newest it can read.
    public static let currentFormat = 1

    public enum Outcome: Codable, Hashable, Sendable {
        /// The operation was accepted. It is in flight until a later record says otherwise.
        case started
        /// A provisioning checkpoint was reached; the operation may continue.
        case checkpoint(ProvisioningStage)
        case completed
        case failed(GuesthouseError)
        /// Contact was lost; the true outcome must be reconciled before anything is retried.
        case unknown
    }

    public let format: Int
    public let id: OperationID
    public let environmentID: EnvironmentID
    public let operation: JournalOperation
    public let timestamp: Date
    public let outcome: Outcome

    public init(id: OperationID, environmentID: EnvironmentID, operation: JournalOperation, timestamp: Date, outcome: Outcome) {
        format = Self.currentFormat
        self.id = id
        self.environmentID = environmentID
        self.operation = operation
        self.timestamp = timestamp
        self.outcome = outcome
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(Int.self, forKey: .format)
        guard (1...Self.currentFormat).contains(format) else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "journal record format \(format) is not readable by this build")
        }
        self.format = format
        id = try c.decode(OperationID.self, forKey: .id)
        environmentID = try c.decode(EnvironmentID.self, forKey: .environmentID)
        operation = try c.decode(JournalOperation.self, forKey: .operation)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
    }

    /// Whether this record leaves the operation in flight. A failure whose error says the
    /// outcome is unknown is not terminal: the mutation's result is still unestablished.
    ///
    /// A cancellation is one of those. It can reach the runtime after the host mutation has
    /// partly or fully happened, which is why `GuesthouseError.canceled` offers inspection as
    /// its first recovery action; the operation stays unresolved until that inspection has
    /// settled it (AGENTS.md: never retry a mutating operation blindly).
    public var leavesInFlight: Bool {
        switch outcome {
        case .started, .checkpoint, .unknown: true
        case .failed(.operationOutcomeUnknown), .failed(.canceled): true
        case .completed, .failed: false
        }
    }
}

/// The result of reading the journal on launch.
public struct JournalReplay: Hashable, Sendable {
    public var records: [JournalRecord]
    /// Operations whose latest record leaves them in flight, keyed by id. Every one of these
    /// has an unknown outcome until the coordinator inspects actual state.
    public var inFlight: [OperationID: JournalRecord]
    /// True when the final line was incomplete, which happens when the process died mid-write.
    /// The partial line is ignored; the operation it belonged to is still listed as in flight
    /// by its previous record, if any. The next append truncates it.
    public var truncatedTail: Bool

    public init(records: [JournalRecord], inFlight: [OperationID: JournalRecord], truncatedTail: Bool) {
        self.records = records
        self.inFlight = inFlight
        self.truncatedTail = truncatedTail
    }
}
