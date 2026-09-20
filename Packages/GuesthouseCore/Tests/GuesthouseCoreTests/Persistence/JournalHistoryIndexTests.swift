import Foundation
import GuesthouseCore
import Testing

@Suite struct JournalHistoryIndexTests {
    private func record(_ outcome: JournalRecord.Outcome = .started,
                        id: OperationID = OperationID(), environment: EnvironmentID = EnvironmentID()) -> JournalRecord {
        JournalRecord(id: id, environmentID: environment, operation: .startEnvironment,
                      timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000), outcome: outcome)
    }

    @Test func fullRuntimeRecordBudgetRetainsIndependentUnresolvedEnvironments() throws {
        var history = JournalHistory()
        for _ in 0..<16_384 { try history.append(record()) }
        #expect(history.records.count == 16_384)
        #expect(history.inFlight.count == 16_384)
        // Direct environment indexing is the complexity guarantee, not a timing threshold.
        let first = try #require(history.records.first), last = try #require(history.records.last)
        for started in [first, last] {
            #expect(throws: StateStoreError.operationUnresolved(started.id)) {
                try history.validateAppend(record(environment: started.environmentID))
            }
        }
    }

    @Test func stagedSettlementAndRejectedAppendKeepTheIndexConsistent() throws {
        var published = JournalHistory()
        let first = record(), other = record()
        try published.append(first)
        try published.append(other)
        var staged = published
        let invalid = record(.completed, id: first.id, environment: other.environmentID)
        #expect(throws: StateStoreError.inconsistentRecord(first.id)) { try staged.append(invalid) }
        for started in [first, other] {
            #expect(throws: StateStoreError.operationUnresolved(started.id)) {
                try staged.validateAppend(record(environment: started.environmentID))
            }
        }
        try staged.append(record(.unknown, id: first.id, environment: first.environmentID))
        #expect(throws: StateStoreError.operationUnresolved(first.id)) {
            try staged.validateAppend(record(environment: first.environmentID))
        }
        try staged.append(record(.notApplied, id: first.id, environment: first.environmentID))
        let next = record(environment: first.environmentID)
        try staged.append(next)
        #expect(staged.inFlight[next.id] == next && staged.inFlight[first.id] == nil)
        #expect(throws: StateStoreError.operationUnresolved(first.id)) {
            try published.validateAppend(next)
        }
        #expect(published.inFlight.count == 2 && published.records.count == 2)
    }
}
