import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStoreFinalRecordTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "StateStoreFinalRecord-\(UUID().uuidString)")

    enum Contradiction: Sendable {
        case orphanedOutcome, duplicateStart, concurrentStart, changedEnvironment
        case changedOperation, outcomeAfterSettlement, conflictingFailureIdentity
    }

    @Test(arguments: [
        Contradiction.orphanedOutcome, .duplicateStart, .concurrentStart, .changedEnvironment,
        .changedOperation, .outcomeAfterSettlement, .conflictingFailureIdentity,
    ])
    func completeInvalidFinalRecordIsPreservedAndBlocksBegin(contradiction: Contradiction) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let id = OperationID()
        let environment = EnvironmentID()
        let started = record(id: id, environment: environment, outcome: .started)
        let completed = record(id: id, environment: environment, outcome: .completed)
        let prefix: [JournalRecord]
        let final: JournalRecord
        switch contradiction {
        case .orphanedOutcome:
            prefix = []
            final = completed
        case .duplicateStart:
            prefix = [started]
            final = started
        case .concurrentStart:
            prefix = [started]
            final = record(id: OperationID(), environment: environment, outcome: .started)
        case .changedEnvironment:
            prefix = [started]
            final = record(id: id, environment: EnvironmentID(), outcome: .completed)
        case .changedOperation:
            prefix = [started]
            final = record(id: id, environment: environment, operation: .stopEnvironment, outcome: .completed)
        case .outcomeAfterSettlement:
            prefix = [started, completed]
            final = record(id: id, environment: environment, outcome: .unknown)
        case .conflictingFailureIdentity:
            prefix = [started]
            final = record(id: id, environment: environment, outcome: .failed(.operationOutcomeUnknown(OperationID())))
        }
        var original = Data()
        for record in prefix {
            original.append(try JSONEncoder().encode(record))
            original.append(0x0A)
        }
        let finalBytes = try JSONEncoder().encode(final)
        // These are fully decodable records whose meaning is invalid, with no torn JSON.
        try #require(try JSONDecoder().decode(JournalRecord.self, from: finalBytes) == final)
        original.append(finalBytes)
        let (store, url) = try fixture(original)
        let expected = StateStoreError.corruptJournal(line: prefix.count + 1)
        await #expect(throws: expected) { try await store.replay() }
        #expect(try Data(contentsOf: url) == original)
        await #expect(throws: expected) {
            try await store.begin(.exportWork, for: EnvironmentID())
        }
        #expect(try Data(contentsOf: url) == original)
        await #expect(throws: expected) { try await store.replay() }
    }

    @Test(arguments: [
        (0, StateStoreError.corruptJournal(line: 1)),
        (-1, StateStoreError.corruptJournal(line: 1)),
        (2, StateStoreError.unsupportedJournalFormat(line: 1, format: 2)),
    ])
    func finalRecordFormatErrorsRemainDistinctWithoutANewline(format: Int, expected: StateStoreError) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let started = record(id: OperationID(), environment: EnvironmentID(), outcome: .started)
        let text = String(decoding: try JSONEncoder().encode(started), as: UTF8.self)
        try #require(text.contains("\"format\":1"))
        let original = Data(text.replacingOccurrences(of: "\"format\":1", with: "\"format\":\(format)").utf8)
        let (store, url) = try fixture(original)
        await #expect(throws: expected) { try await store.replay() }
        await #expect(throws: expected) {
            try await store.begin(.exportWork, for: EnvironmentID())
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: ["id", "operation"])
    func completeFinalRecordWithAnUndecodableFieldIsPreserved(field: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let started = record(id: OperationID(), environment: EnvironmentID(), outcome: .started)
        let encoded = try JSONEncoder().encode(started)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[field] = "not-a-valid-\(field)"
        try await requireCompleteJSONRefused(JSONSerialization.data(withJSONObject: object))
    }

    @Test(arguments: ["{}", "[]", "null", "false", "\"not a record\""])
    func completeJSONWithoutARecordIsNeverTreatedAsATornWrite(json: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await requireCompleteJSONRefused(Data(json.utf8))
    }

    @Test func incompleteFinalJSONStillAllowsAnInspectedOperationToSettle() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let id = OperationID()
        let environment = EnvironmentID()
        let started = record(id: id, environment: environment, outcome: .started)
        let completed = record(id: id, environment: environment, outcome: .completed)
        var prefix = try JSONEncoder().encode(started)
        prefix.append(0x0A)
        let completeLine = try JSONEncoder().encode(completed)
        let original = prefix + completeLine.dropLast()
        let (store, url) = try fixture(original)
        let replay = try await store.replay()
        #expect(replay.truncatedTail)
        #expect(replay.records == [started])
        #expect(replay.inFlight[id] == started)
        await #expect(throws: StateStoreError.operationUnresolved(id)) {
            try await store.begin(.stopEnvironment, for: environment)
        }
        #expect(try Data(contentsOf: url) == original)
        try await store.append(completed)
        let settled = try await store.replay()
        #expect(settled.records == [started, completed])
        #expect(!settled.truncatedTail)
        #expect(settled.inFlight.isEmpty)
    }

    private func requireCompleteJSONRefused(_ original: Data) async throws {
        // Parsing succeeds, but this complete JSON value cannot be a JournalRecord.
        _ = try JSONSerialization.jsonObject(with: original, options: .fragmentsAllowed)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: original) }
        let (store, url) = try fixture(original)
        let expected = StateStoreError.corruptJournal(line: 1)
        await #expect(throws: expected) { try await store.replay() }
        await #expect(throws: expected) { try await store.begin(.exportWork, for: EnvironmentID()) }
        #expect(try Data(contentsOf: url) == original)
    }

    private func record(
        id: OperationID, environment: EnvironmentID,
        operation: JournalOperation = .startEnvironment, outcome: JournalRecord.Outcome
    ) -> JournalRecord {
        JournalRecord(id: id, environmentID: environment, operation: operation,
                      timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000), outcome: outcome)
    }

    private func fixture(_ bytes: Data) throws -> (StateStore, URL) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: StateStore.journalFileName)
        try bytes.write(to: url)
        return (try StateStore(rootURL: root), url)
    }
}
