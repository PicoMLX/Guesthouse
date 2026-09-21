import Foundation
import GuesthouseCore
import Testing

@Suite struct JournalTailCapacityTests {
    @Test(arguments: [false, true], [0, 4_096])
    func completionRequiresItsOriginalSpaceAndNewline(sorted: Bool, padding: Int) throws {
        let start = JournalRecord(id: OperationID(), environmentID: EnvironmentID(),
            operation: .startEnvironment, timestamp: Date(timeIntervalSinceReferenceDate: 0), outcome: .started)
        let finish = JournalRecord(id: start.id, environmentID: start.environmentID,
            operation: start.operation, timestamp: start.timestamp,
            outcome: .failed(.unsupportedHost(.insufficientMemory(foundBytes: .max, minimumBytes: .max))))
        let encoder = JSONEncoder()
        if sorted { encoder.outputFormatting = [.sortedKeys] }
        let prefix = try encoder.encode(start) + Data(repeating: 32, count: padding) + Data([10])
        let completion = try encoder.encode(finish), tail = Data(completion.dropLast())
        let budget = prefix.count + completion.count + 1
        let accepted = try JournalReplayChunk(prefix + tail, maximumByteCount: budget)
        #expect(accepted.truncatedTail && accepted.validatedByteCount == prefix.count)
        #expect(accepted.history.records == [start])
        for capacity in [budget - 1, budget - 2] {
            #expect(throws: StateStoreError.corruptJournal(line: 2)) {
                try JournalReplayChunk(prefix + tail, maximumByteCount: capacity)
            }
        }
        // A caller supplying only the suffix must subtract the original prefix itself.
        let history = try JournalReplayChunk(prefix).history
        #expect(try JournalReplayChunk(tail, following: history,
            maximumByteCount: budget - prefix.count).truncatedTail)
        #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try JournalReplayChunk(tail, following: history, maximumByteCount: completion.count)
        }
        let complete = try JournalReplayChunk(prefix + completion + Data([10]), maximumByteCount: budget)
        #expect(complete.history.records == [start, finish] && !complete.truncatedTail)
        #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
            try JournalReplayChunk(prefix + completion + Data([10]), maximumByteCount: budget - 1)
        }
    }
}
