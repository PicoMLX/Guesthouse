import Foundation

/// One line of the append-only operation journal.
///
/// The journal is written before the UI learns about a change and replayed on launch to find
/// operations that never reported a result (MVP-PLAN.md §3: "Persist operation identifiers
/// and completed checkpoints before updating the UI").
public struct JournalRecord: Codable, Hashable, Sendable {
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

    public let id: OperationID
    public let environmentID: EnvironmentID
    /// A stable operation kind such as `startEnvironment`; never free-form text.
    public let operation: String
    public let timestamp: Date
    public let outcome: Outcome

    public init(id: OperationID, environmentID: EnvironmentID, operation: String, timestamp: Date, outcome: Outcome) {
        self.id = id
        self.environmentID = environmentID
        self.operation = operation
        self.timestamp = timestamp
        self.outcome = outcome
    }

    /// Whether this record leaves the operation in flight.
    public var leavesInFlight: Bool {
        switch outcome {
        case .started, .checkpoint, .unknown: true
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
    /// by its previous record, if any.
    public var truncatedTail: Bool

    public init(records: [JournalRecord], inFlight: [OperationID: JournalRecord], truncatedTail: Bool) {
        self.records = records
        self.inFlight = inFlight
        self.truncatedTail = truncatedTail
    }
}
