import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct StateStoreJournalTests {
    @Test func reopenRetainsUnresolvedIdentityAndSettlesOnlyFromEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try await fixture.open(), environment = EnvironmentID()
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.begin(.startEnvironment, for: environment)
        }
        #expect(try await store.replay().records.isEmpty)
        let id = try await store.begin(.startEnvironment, for: environment)
        let unknown = record(id, environment, .unknown)
        try await store.append(unknown)
        await store.close()
        let reopened = try await fixture.open()
        #expect(try await reopened.replay().inFlight == [id: unknown])
        await #expect(throws: StateStoreError.operationUnresolved(id)) {
            try await reopened.begin(.startEnvironment, for: environment)
        }
        _ = try await reopened.replay()
        try await reopened.append(record(id, environment, .notApplied))
        #expect(try await reopened.replay().inFlight.isEmpty)
        _ = try await reopened.begin(.startEnvironment, for: environment)
        await reopened.close()
    }

    @Test func missingReplayCreatesNothingAndCloseRefusesFurtherUse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try await fixture.open()
        #expect(try await store.replay().records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        await store.close()
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.begin(.stopEnvironment, for: EnvironmentID())
        }
    }

    @Test func tornTailPreservesBytesAndRequiresExplicitRepair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = OperationID(), environment = EnvironmentID(), started = record(id, environment, .started)
        var bytes = try line(started)
        // A prefix of the next supported record is incomplete, not a new accepted operation.
        bytes.append(Data("{\"format\":2,".utf8))
        try fixture.write(bytes)
        let store = try await fixture.open()
        let replay = try await store.replay()
        #expect(replay.truncatedTail)
        #expect(replay.inFlight == [id: started])
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.append(record(id, environment, .completed))
        }
        #expect(try Data(contentsOf: fixture.journal) == bytes)
        await store.close()
        let reopened = try await fixture.open()
        #expect(try await reopened.replay().truncatedTail)
        #expect(try Data(contentsOf: fixture.journal) == bytes)
        await reopened.close()
    }

    @Test(arguments: ["not JSON\n", "{\"format\":99}\n", "{\"format\":1}", "{}"])
    func corruptAndUnsupportedRecordsArePreserved(raw: String) async throws {
        let fixture = try Fixture(), bytes = Data(raw.utf8)
        defer { fixture.remove() }
        try fixture.write(bytes)
        let store = try await fixture.open()
        await #expect(throws: StateStoreError.self) { try await store.replay() }
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.begin(.stopEnvironment, for: EnvironmentID())
        }
        #expect(try Data(contentsOf: fixture.journal) == bytes)
        await store.close()
    }

    @Test func completeFinalRecordWithoutNewlineGetsASeparator() async throws {
        let fixture = try Fixture(), id = OperationID(), environment = EnvironmentID()
        defer { fixture.remove() }
        let started = record(id, environment, .started), completed = record(id, environment, .completed)
        try fixture.write(Data(line(started).dropLast()))
        let store = try await fixture.open()
        #expect(try await store.replay().records == [started])
        try await store.append(completed)
        #expect(try await store.replay().records == [started, completed])
        #expect(try Data(contentsOf: fixture.journal) == line(started) + line(completed))
        await store.close()
    }

    @Test(arguments: ["partial", "file", "directory"])
    func failedAppendIsUncertainAndCannotBeBlindlyRetried(stage: String) async throws {
        let fixture = try Fixture(), id = OperationID(), environment = EnvironmentID()
        defer { fixture.remove() }
        let started = record(id, environment, .started), completed = record(id, environment, .completed)
        let before = try line(started)
        try fixture.write(before)
        let enabled = Mutex(false), writes = Mutex(0)
        let hooks = StateStoreHooks(journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            if stage == "partial" {
                try StateFileIO.writeAll(fd, Data("{".utf8), name: .journal)
                throw StateStoreError.fileUnwritable(name: .journal)
            }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }, synchronize: { fd, name in
            if enabled.withLock({ $0 }), (stage == "file" && name == .journal) || (stage == "directory" && name == .stateDirectory) {
                throw StateStoreError.fileUnwritable(name: name)
            }
            try StateFileIO.fullySynchronize(fd, name: name)
        })
        let store = try await fixture.open(hooks: hooks)
        _ = try await store.replay()
        enabled.withLock { $0 = true }
        let failure = StateStoreError.fileUnwritable(name: stage == "directory" ? .stateDirectory : .journal)
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: failure)) { try await store.append(completed) }
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) { try await store.append(completed) }
        #expect(writes.withLock { $0 } == 1)
        let after = try Data(contentsOf: fixture.journal)
        #expect(after == before + (stage == "partial" ? Data("{".utf8) : try line(completed)))
        await store.close()
        let reopened = try await fixture.open(), replay = try await reopened.replay()
        #expect(replay.truncatedTail == (stage == "partial"))
        #expect(replay.inFlight.isEmpty == (stage != "partial"))
        #expect(try Data(contentsOf: fixture.journal) == after)
        await reopened.close()
    }

    @Test func invalidTransitionAndFullBudgetLeaveOriginalBytes() async throws {
        let fixture = try Fixture(), id = OperationID(), environment = EnvironmentID()
        defer { fixture.remove() }
        let start = record(id, environment, .started)
        let initial = try line(start)
        // JSON trailing whitespace keeps the first record valid at the byte limit.
        var full = Data(initial.dropLast())
        full.append(Data(repeating: 0x20, count: StateFileIO.maximumJournalBytes - full.count - 1))
        full.append(0x0A)
        try fixture.write(full)
        let store = try await fixture.open()
        _ = try await store.replay()
        await #expect(throws: StateStoreError.inconsistentRecord(id)) { try await store.append(start) }
        _ = try await store.replay()
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.append(record(id, environment, .completed))
        }
        #expect(try Data(contentsOf: fixture.journal) == full)
        await store.close()
    }

    private func record(_ id: OperationID, _ environment: EnvironmentID, _ outcome: JournalRecord.Outcome) -> JournalRecord {
        JournalRecord(id: id, environmentID: environment, operation: .startEnvironment,
                      timestamp: Date(timeIntervalSince1970: 1), outcome: outcome)
    }
    private func line(_ record: JournalRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(record) + Data([0x0A])
    }
    private struct Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var journal: URL { root.appending(path: "state/journal.ndjson") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-journal-\(UUID())")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            _ = try RuntimeStorage(root: root)
        }
        func open(hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(existingRoot: root) }, hooks: hooks)
        }
        func write(_ bytes: Data) throws {
            try bytes.write(to: journal)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
