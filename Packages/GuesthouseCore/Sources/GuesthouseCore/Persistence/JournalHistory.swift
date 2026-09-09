/// The record-identity and unresolved-operation rules shared by journal append and replay.
/// Extracted from the retained StateStore (MVP-PLAN.md §3). This is an in-memory value,
/// not a file reader, writer, lock, operation admission authority or diagnostic sink.
///
/// The runtime must refresh under its journal lock before validation, keep that lock through
/// the write and durability barriers, and publish the resulting history only after success.
/// Replay must stage a copy and discard it if any line fails. Neither a record's presence
/// here nor an error category independently proves the operation's actual outcome.
public struct JournalHistory: Sendable {
    public private(set) var records: [JournalRecord] = []
    public private(set) var inFlight: [OperationID: JournalRecord] = [:]

    private struct Identity: Sendable {
        let environment: EnvironmentID
        let operation: JournalOperation
    }

    private var identities: [OperationID: Identity] = [:]
    /// A terminal record prevents all subsequent records against the same operation ID.
    private var settled: Set<OperationID> = []

    public init() {}

    /// Checks a proposed record without reserving an identity or changing this value.
    public func validateAppend(_ record: JournalRecord) throws(StateStoreError) {
        // Naming another operation, development Mac or checkpoint stage leaves recovery
        // with conflicting answers to the question of what must be inspected.
        guard record.isSelfConsistent else { throw .inconsistentRecord(record.id) }
        switch (record.outcome, identities[record.id]) {
        case (.started, nil):
            if let unresolved = inFlight.values.first(where: { $0.environmentID == record.environmentID }) {
                throw .operationUnresolved(unresolved.id)
            }
        case (.started, .some), (_, nil):
            throw .inconsistentRecord(record.id)
        case (_, .some(let identity)):
            guard !settled.contains(record.id),
                  identity.environment == record.environmentID,
                  identity.operation == record.operation else {
                throw .inconsistentRecord(record.id)
            }
        }
    }

    /// Validates and adds a record to this value only. Rejection changes nothing.
    /// The same rule applies to restored records and proposed writes; a byte reader maps
    /// a rejected on-disk record to its corrupt-journal line without adopting that prefix.
    public mutating func append(_ record: JournalRecord) throws(StateStoreError) {
        try validateAppend(record)
        records.append(record)
        identities[record.id] = Identity(environment: record.environmentID, operation: record.operation)
        if record.leavesInFlight {
            inFlight[record.id] = record
        } else {
            inFlight.removeValue(forKey: record.id)
            settled.insert(record.id)
        }
    }
}
