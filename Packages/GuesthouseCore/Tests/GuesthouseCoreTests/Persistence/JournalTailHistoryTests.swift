import Foundation
import GuesthouseCore
import Testing

@Suite struct JournalTailHistoryTests {
    @Test(arguments: [4_096, 16 * 1_024 * 1_024 - 1])
    func oversizedASCIITailRefusesWithManyUnresolvedOperations(byteCount: Int) throws {
        var history = JournalHistory()
        for _ in 0..<512 {
            try history.append(JournalRecord(id: OperationID(), environmentID: EnvironmentID(),
                operation: .startEnvironment, timestamp: Date(timeIntervalSinceReferenceDate: 0), outcome: .started))
        }
        let prefix = Data("{\"timestamp\":".utf8)
        let tail = prefix + Data(repeating: 49, count: byteCount - prefix.count)
        #expect(throws: StateStoreError.corruptJournal(line: 513)) {
            try JournalReplayChunk(tail, following: history)
        }
        #expect(history.records.count == 512 && history.inFlight.count == 512)
        // A real continuation with wide numeric fields remains recoverable against the
        // same history. Existing every-cut tests exercise all closed operation/outcome shapes.
        let started = try #require(history.records.last)
        let completion = JournalRecord(id: started.id, environmentID: started.environmentID,
            operation: started.operation, timestamp: Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude),
            outcome: .failed(.unsupportedHost(.insufficientMemory(foundBytes: .max, minimumBytes: .max))))
        let bytes = try JSONEncoder().encode(completion)
        let chunk = try JournalReplayChunk(Data(bytes.dropLast()), following: history)
        #expect(chunk.truncatedTail && chunk.validatedByteCount == 0)
        #expect(chunk.history.records == history.records)
    }

    @Test(arguments: [false, true])
    func impossibleAppendsRefuseWithoutAdoptingStagedHistory(sorted: Bool) throws {
        let id = OperationID(), environment = EnvironmentID()
        func record(_ outcome: JournalRecord.Outcome, id candidate: OperationID? = nil,
                    environment target: EnvironmentID? = nil,
                    operation: JournalOperation = .startEnvironment) -> JournalRecord {
            JournalRecord(id: candidate ?? id, environmentID: target ?? environment,
                          operation: operation, timestamp: Date(timeIntervalSinceReferenceDate: 0), outcome: outcome)
        }
        let encoder = JSONEncoder()
        if sorted { encoder.outputFormatting = [.sortedKeys] }
        let start = record(.started), finish = record(.completed)
        let prefix = try encoder.encode(start) + Data([10])
        let settled = try prefix + encoder.encode(finish) + Data([10])
        for (bytes, invalid) in [
            (settled, record(.started)), (settled, record(.unknown)),
            (prefix, record(.started, id: OperationID())),
            (prefix, record(.completed, id: OperationID())),
            (prefix, record(.completed, environment: EnvironmentID())),
            (prefix, record(.completed, operation: .stopEnvironment))
        ] {
            let history = try JournalReplayChunk(bytes).history
            let tail = try encoder.encode(invalid).dropLast()
            #expect(throws: StateStoreError.corruptJournal(line: history.records.count + 1)) {
                try JournalReplayChunk(bytes + tail)
            }
            #expect(throws: StateStoreError.corruptJournal(line: history.records.count + 1)) {
                try JournalReplayChunk(Data(tail), following: history)
            }
            #expect(history.records.first == start)
        }
        // A continuation cannot name any identity other than the staged unresolved one,
        // even when its second field stops inside the UUID rather than at a delimiter.
        let other = id.uuid.uuidString.first == "A" ? "B" : "A"
        let partial = Data(("{\"outcome\":{\"completed\":{}},\"id\":\"" + other).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try JournalReplayChunk(prefix + partial)
        }
    }

    @Test func exhaustedPartialIdentityCannotBecomeANewStart() throws {
        var history = JournalHistory()
        let environment = EnvironmentID()
        let stem = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA"
        let tail = Data(("{\"outcome\":{\"started\":{}},\"id\":\"" + stem).utf8)
        for digit in "0123456789ABCDEF" {
            #expect(try JournalReplayChunk(tail, following: history).truncatedTail)
            let id = OperationID(uuid: try #require(UUID(uuidString: stem + String(digit))))
            for outcome in [JournalRecord.Outcome.started, .completed] {
                try history.append(JournalRecord(id: id, environmentID: environment, operation: .startEnvironment,
                                                  timestamp: Date(), outcome: outcome))
            }
        }
        #expect(throws: StateStoreError.corruptJournal(line: 33)) {
            try JournalReplayChunk(tail, following: history)
        }
    }
}
