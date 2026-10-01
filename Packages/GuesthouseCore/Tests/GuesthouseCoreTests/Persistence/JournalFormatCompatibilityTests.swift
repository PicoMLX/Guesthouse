import Foundation
import GuesthouseCore
import Testing

@Suite struct JournalFormatCompatibilityTests {
    @Test(arguments: JournalOperation.allCases.filter { $0 != .stopEnvironment })
    func shutdownRefusalCannotSettleAnotherOperationOrAuthorizeItsTailRepair(operation: JournalOperation) throws {
        let id = OperationID(), environment = EnvironmentID()
        let start = JournalRecord(id: id, environmentID: environment, operation: operation, timestamp: Date(), outcome: .started)
        let failed = JournalRecord(id: id, environmentID: environment, operation: operation, timestamp: Date(),
                                   outcome: .failed(.guestShutdownRefused(environment)))
        var history = JournalHistory(); try history.append(start)
        #expect(!failed.isSelfConsistent)
        #expect(throws: StateStoreError.inconsistentRecord(id)) { try history.append(failed) }
        for sorted in [false, true] {
            let encoder = JSONEncoder(); if sorted { encoder.outputFormatting = [.sortedKeys] }
            let bytes = try encoder.encode(failed)
            #expect(throws: StateStoreError.corruptJournal(line: 2)) { try JournalReplayChunk(bytes, following: history) }
            #expect(throws: StateStoreError.corruptJournal(line: 2)) { try JournalReplayChunk(bytes.dropLast(), following: history) }
        }
        #expect(history.inFlight[id] == start)
    }

    @Test(arguments: [false, true])
    func legacyStartsAndTailsRemainReadableBeforeNewRefusal(sorted: Bool) throws {
        let id = OperationID(), environment = EnvironmentID()
        let start = JournalRecord(id: id, environmentID: environment, operation: .stopEnvironment, timestamp: Date(), outcome: .started)
        let encoder = JSONEncoder()
        if sorted { encoder.outputFormatting = [.sortedKeys] }
        let legacy = Data(String(decoding: try encoder.encode(start), as: UTF8.self).replacingOccurrences(of: "\"format\":3", with: "\"format\":2").utf8)
        #expect(try JSONDecoder().decode(JournalRecord.self, from: legacy).format == 2)
        for length in 1..<legacy.count {
            #expect(try JournalReplayChunk(Data(legacy.prefix(length))).truncatedTail)
        }
        let failed = JournalRecord(id: id, environmentID: environment, operation: .stopEnvironment,
                                   timestamp: Date(), outcome: .failed(.guestShutdownRefused(environment)))
        #expect(failed.format == 3)
        let current = try encoder.encode(failed)
        let history = try JournalReplayChunk(legacy + Data([10])).history
        #expect(try JournalReplayChunk(current, following: history).history.inFlight.isEmpty)
        for length in 1..<current.count {
            #expect(try JournalReplayChunk(Data(current.prefix(length)), following: history).truncatedTail)
        }
        // A new error mislabeled as legacy is corruption, never an authorized repair prefix.
        let mislabeled = Data(String(decoding: current, as: UTF8.self).replacingOccurrences(of: "\"format\":3", with: "\"format\":2").utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 2)) { try JournalReplayChunk(mislabeled, following: history) }
        #expect(throws: StateStoreError.corruptJournal(line: 2)) { try JournalReplayChunk(mislabeled.dropLast(), following: history) }
    }
}
