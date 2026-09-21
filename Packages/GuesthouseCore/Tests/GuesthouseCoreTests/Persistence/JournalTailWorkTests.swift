import Foundation
@testable import GuesthouseCore
import Testing

@Suite struct JournalTailWorkTests {
    private func unresolvedHistory(_ count: Int) throws -> JournalHistory {
        var history = JournalHistory()
        for _ in 0..<count {
            try history.append(JournalRecord(id: OperationID(), environmentID: EnvironmentID(),
                operation: .startEnvironment, timestamp: Date(timeIntervalSinceReferenceDate: 0), outcome: .started))
        }
        return history
    }

    @Test(arguments: [1, 16_384], ["1e+999", "4.6728494007670807e+3"])
    func dateWitnessWorkDoesNotMultiplyByUnresolvedOperations(count: Int, token: String) throws {
        let history = try unresolvedHistory(count)
        // The outcome rejects the start shape before the date, while identity fields
        // have not arrived yet. Every continuation must visit this same date token.
        let tail = Data(("{\"outcome\":{\"completed\":{}},\"timestamp\":" + token).utf8)
        // No space remains for a completion: even a genuine witness must exhaust
        // all candidates. Both unsuccessful and successful searches are memoized.
        let refused = JournalTailPrefix.evaluate(tail, following: history, maximumRecordBytes: tail.count)
        #expect(!refused.accepted)
        #expect(refused.dateCompletionSearches == 1)
        let repeated = JournalTailPrefix.evaluate(tail, following: history, maximumRecordBytes: tail.count)
        #expect(!repeated.accepted && repeated.dateCompletionSearches == 1)
        #expect(history.records.count == count && history.inFlight.count == count)
    }

    @Test(arguments: [1, 16_384])
    func memoizedSearchKeepsWitnessAndCorruptionDecisions(count: Int) throws {
        let history = try unresolvedHistory(count)
        let prefix = "{\"outcome\":{\"completed\":{}},\"timestamp\":"
        let replay = try JournalReplayChunk(Data((prefix + "4.6728494007670807e+3").utf8), following: history)
        #expect(replay.truncatedTail && replay.validatedByteCount == 0)
        #expect(replay.history.records == history.records)
        #expect(throws: StateStoreError.corruptJournal(line: count + 1)) {
            try JournalReplayChunk(Data((prefix + "1e+999").utf8), following: history)
        }
    }
}
