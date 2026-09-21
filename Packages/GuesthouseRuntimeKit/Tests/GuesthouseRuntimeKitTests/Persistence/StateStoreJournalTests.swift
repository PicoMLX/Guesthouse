import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Retains #57's append/recovery/durability cases with runtime-owned fixtures, not host/VM work.
@Suite(.timeLimit(.minutes(1))) struct StateStoreJournalTests {
    @Test(arguments: [false, true], [false, true])
    func preBorrowBindingFailureCannotAuthorizeRestoredHistory(firstAppend: Bool, initiallyMissing: Bool) async throws {
        let fixture = try Fixture(), reads = Mutex(0), writes = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }, journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        let original = try JSONEncoder().encode(Self.record()) + Data([10])
        let other = try JSONEncoder().encode(Self.record()) + Data([10])
        if !initiallyMissing {
            try fixture.write(original)
            _ = try await store.replay()
        }
        let detached = fixture.base.appending(path: "retained-directory")
        let conflicting = fixture.base.appending(path: "conflicting-directory")
        try #require(rename(fixture.state.path, detached.path) == 0)
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        try fixture.write(other)
        if firstAppend {
            await #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        } else {
            await #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try await store.replay() }
        }
        try #require(rename(fixture.state.path, conflicting.path) == 0)
        try #require(rename(detached.path, fixture.state.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        }
        #expect(reads.withLock { $0 } == (initiallyMissing ? 0 : 1) && writes.withLock { $0 } == 0)
        if initiallyMissing { #expect(!FileManager.default.fileExists(atPath: fixture.journal.path)) }
        else { #expect(try fixture.bytes() == original) }
        #expect(try Data(contentsOf: conflicting.appending(path: "journal.ndjson")) == other)
    }

    @Test func ordinaryDirectoryContentionDoesNotPoisonUnobservedJournal() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let fd = Darwin.open(fixture.state.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        try #require(flock(fd, LOCK_UN) == 0)
        #expect(try await store.replay().records.isEmpty)
        let id = try await store.begin(.startEnvironment, for: EnvironmentID())
        #expect(try await store.replay().records.map(\.id) == [id])
    }

    @Test(arguments: [false, true])
    func initialPreparationFailureCannotAuthorizeTruncatedJournal(firstAppend: Bool) async throws {
        let fixture = try Fixture(), fail = Mutex(true), writes = Mutex(0), started = Self.record()
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { fd, name in
            if fail.withLock({ $0 }) { throw StateStoreError.fileUnwritable(name: .journal) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }, journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        try fixture.write(JSONEncoder().encode(started) + Data([10]))
        if firstAppend {
            await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        } else {
            await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) { try await store.replay() }
        }
        try fixture.write(Data())
        fail.withLock { $0 = false }
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: started.environmentID)
            }
        }
        #expect(writes.withLock { $0 } == 0)
        #expect(try fixture.bytes().isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func initialReadFailureCannotAuthorizeLaterBegin(firstAppend: Bool, truncate: Bool) async throws {
        let fixture = try Fixture(), attempts = Mutex(0), started = Self.record()
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw StateStoreError.fileUnreadable(name: .journal) }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let original = try JSONEncoder().encode(started) + Data([10])
        try fixture.write(original)
        var before = stat(), after = stat()
        try #require(lstat(fixture.journal.path, &before) == 0)
        if firstAppend {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        } else {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        let changed = truncate ? Data() : try JSONEncoder().encode(Self.record()) + Data([10])
        try fixture.write(changed)
        try #require(lstat(fixture.journal.path, &after) == 0)
        try #require(StateFileIdentity(before) == StateFileIdentity(after))
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: started.environmentID)
            }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(attempts.withLock { $0 } == 1)
        #expect(try fixture.bytes() == changed)
    }

    @Test(arguments: [false, true])
    func initialCorruptReadCannotAuthorizeBeginAfterTruncation(firstAppend: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        let original = try JSONEncoder().encode(started) + Data("\nnot JSON\n".utf8)
        try fixture.write(original)
        if firstAppend {
            await #expect(throws: StateStoreError.corruptJournal(line: 2)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        } else {
            await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await store.replay() }
        }
        try fixture.write(Data())
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: started.environmentID)
            }
        }
        #expect(try fixture.bytes().isEmpty)
        try fixture.write(original)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(try fixture.bytes() == original)
    }

    @Test(arguments: [false, true])
    func failedInitialAppendPreparationCannotAcceptReplacement(deniedOpen: Bool) async throws {
        let fixture = try Fixture(), fail = Mutex(!deniedOpen), started = Self.record()
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { fd, name in
            if fail.withLock({ $0 }) { throw StateStoreError.fileUnwritable(name: .journal) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }))
        let original = try JSONEncoder().encode(started) + Data([10])
        try fixture.write(original)
        if deniedOpen { try #require(chmod(fixture.journal.path, 0) == 0) }
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        let retained = fixture.state.appending(path: "retained-initial")
        try #require(rename(fixture.journal.path, retained.path) == 0)
        try fixture.write(Data())
        fail.withLock { $0 = false }
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: started.environmentID)
            }
        }
        #expect(try fixture.bytes().isEmpty)
        try #require(chmod(retained.path, 0o600) == 0)
        #expect(try Data(contentsOf: retained) == original)
    }

    @Test func appendBudgetAllowsExactBoundaryAndRefusesOverflow() throws {
        let limit = StateFileIO.maximumJournalBytes, records = StateJournalCache.maximumRecords
        try StateJournalAppend.requireCapacity(bytes: limit - 10, records: records - 1, additionalBytes: 10)
        for values in [(limit - 10, records - 1, 11), (0, records, 1), (Int.max, 0, 1), (0, 0, Int.max)] {
            #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                try StateJournalAppend.requireCapacity(bytes: values.0, records: values.1, additionalBytes: values.2)
            }
        }
    }

    @Test(arguments: [Data("not json".utf8), Data("{]".utf8), Data([123, 34, 0xff]), Data([123, 0])])
    func impossibleTailRefusesAppendWithoutErasingEvidence(tail: Data) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        try await store.append(started)
        let original = try fixture.bytes() + tail
        try fixture.write(original)
        await #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try await store.append(Self.record(matching: started, outcome: .completed))
        }
        #expect(try fixture.bytes() == original)
    }

    @Test func fullJournalRefusesBeforeRepairingItsTornTail() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        let encoder = JSONEncoder()
        var original = try encoder.encode(started)
        // Valid JSON whitespace fills the byte budget without fabricating thousands of operations.
        original.append(Data(repeating: 32, count: StateFileIO.maximumJournalBytes - original.count - 2))
        original.append(contentsOf: [10, 123])
        try fixture.write(original)
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.append(Self.record(matching: started, outcome: .completed))
        }
        #expect(try fixture.bytes() == original)
    }

    @Test(arguments: JournalOperation.allCases)
    func beginPersistsEveryOperationBeforeReturning(operation: JournalOperation) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), environment = EnvironmentID()
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let id = try await store.begin(operation, for: environment, at: date)
        let expected = JournalRecord(id: id, environmentID: environment, operation: operation, timestamp: date, outcome: .started)
        let reopened = try await fixture.open()
        let replay = try await reopened.replay()
        #expect(replay.records == [expected] && replay.inFlight[id] == expected)
        #expect(!replay.truncatedTail)
        #expect(try fixture.bytes().last == 0x0A)
    }

    @Test(arguments: [JournalRecord.Outcome.unknown, .failed(.canceled)])
    func unresolvedOutcomesRefuseAnotherStartUntilInspected(outcome: JournalRecord.Outcome) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        try await store.append(started)
        try await store.append(Self.record(matching: started, outcome: outcome))
        await #expect(throws: StateStoreError.operationUnresolved(started.id)) {
            try await store.begin(.stopEnvironment, for: started.environmentID)
        }
        // This represents an explicit inspected result, not an automatic runtime retry.
        try await store.append(Self.record(matching: started, outcome: .notApplied))
        let next = try await store.begin(.stopEnvironment, for: started.environmentID)
        let pending = try await store.replay().inFlight
        #expect(Set(pending.keys) == [next])
    }

    @Test(arguments: [JournalRecord.Outcome.notApplied, .completed, .failed(.runtimeMissing)])
    func settledOutcomesAllowAnotherStart(outcome: JournalRecord.Outcome) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        try await store.append(started)
        try await store.append(Self.record(matching: started, outcome: outcome))
        let next = try await store.begin(.stopEnvironment, for: started.environmentID)
        let pending = try await store.replay().inFlight
        #expect(Set(pending.keys) == [next])
    }

    @Test func invalidIdentityAndPostTerminalWritesPreserveBytes() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        try await store.append(started)
        let initial = try fixture.bytes()
        let wrong = JournalRecord(id: started.id, environmentID: EnvironmentID(), operation: started.operation,
                                  timestamp: started.timestamp, outcome: .completed)
        for rejected in [started, wrong] {
            await #expect(throws: StateStoreError.inconsistentRecord(started.id)) { try await store.append(rejected) }
            #expect(try fixture.bytes() == initial)
        }
        let completed = Self.record(matching: started, outcome: .completed)
        try await store.append(completed)
        let settled = try fixture.bytes()
        await #expect(throws: StateStoreError.inconsistentRecord(started.id)) { try await store.append(completed) }
        #expect(try fixture.bytes() == settled)
    }

    @Test func twoStoresPublishOrRefuseContentionWithoutRetry() async throws {
        let fixture = try Fixture(), first = try await fixture.open(), second = try await fixture.open()
        let ids = await withTaskGroup(of: OperationID?.self) { group in
            for index in 0..<20 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    do { return try await store.begin(.startEnvironment, for: EnvironmentID()) }
                    catch {
                        #expect(error == .fileUnwritable(name: .journal))
                        return nil
                    }
                }
            }
            var ids = Set<OperationID>()
            for await id in group { if let id { ids.insert(id) } }
            return ids
        }
        let reopened = try await fixture.open(), replay = try await reopened.replay()
        #expect(!ids.isEmpty && replay.records.count == ids.count && Set(replay.inFlight.keys) == ids)
    }

    @Test func twoStoresCannotBothStartTheSameEnvironment() async throws {
        let fixture = try Fixture(), stores = [try await fixture.open(), try await fixture.open()]
        let environment = EnvironmentID()
        let results = await withTaskGroup(of: Result<OperationID, StateStoreError>.self) { group in
            for store in stores {
                group.addTask {
                    do { return .success(try await store.begin(.startEnvironment, for: environment)) }
                    catch { return .failure(error) }
                }
            }
            var results: [Result<OperationID, StateStoreError>] = []
            for await result in group { results.append(result) }
            return results
        }
        let replay = try await stores[0].replay(), started = try #require(replay.records.first)
        #expect(replay.records.count == 1)
        #expect(results.filter { if case .success(let id) = $0 { id == started.id } else { false } }.count == 1)
        #expect(results.filter {
            if case .failure(let failure) = $0 {
                failure == .operationUnresolved(started.id) || failure == .fileUnwritable(name: .journal)
            } else { false }
        }.count == 1)
    }

    @Test func confirmedWritesAreRevalidatedAndEveryRecordBarriersItsEntry() async throws {
        let fixture = try Fixture(), calls = Mutex<[StateStoreError.File]>([]), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            calls.withLock { $0.append(name) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }, journalFile: { fd, name in
            calls.withLock { $0.append(name) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }, journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        for _ in 0..<3 { _ = try await store.begin(.startEnvironment, for: EnvironmentID()) }
        #expect(try await store.replay().records.count == 3)
        #expect(reads.withLock { $0 } == 4)
        #expect(calls.withLock { $0 } == [.journal, .stateDirectory, .journal, .stateDirectory, .journal, .stateDirectory])
    }

    @Test(arguments: [false, true])
    func repairsOnlyTornTailsAndSeparatesCompleteUnterminatedRecords(torn: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        let prefix = try JSONEncoder().encode(started)
        var bytes = prefix
        if torn { bytes.append(contentsOf: "\n{\"format\":".utf8) }
        try fixture.write(bytes)
        // Prime the cache twice: an empty refresh must not forget a required separator.
        _ = try await store.replay()
        _ = try await store.replay()
        let completed = Self.record(matching: started, outcome: .notApplied)
        try await store.append(completed)
        let reopened = try await fixture.open(), replay = try await reopened.replay()
        #expect(replay.records == [started, completed] && replay.inFlight.isEmpty && !replay.truncatedTail)
        #expect(try fixture.bytes().starts(with: prefix))
    }

    @Test(arguments: [
        ("{}", StateStoreError.corruptJournal(line: 1)),
        ("{\"format\":1}", .unsupportedJournalFormat(line: 1, format: 1)),
        ("{\"format\":99}", .unsupportedJournalFormat(line: 1, format: 99)),
        ("not JSON\n", .corruptJournal(line: 1)),
    ])
    func refusesCompleteUnreadableRecordsWithoutErasingEvidence(raw: String, failure: StateStoreError) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), bytes = Data(raw.utf8)
        try fixture.write(bytes)
        await #expect(throws: failure) { try await store.begin(.startEnvironment, for: EnvironmentID()) }
        #expect(try fixture.bytes() == bytes)
    }

    @Test func unencodableRecordDoesNotCreateJournal() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        await #expect(throws: StateStoreError.unencodable(name: .journal)) {
            try await store.begin(.startEnvironment, for: EnvironmentID(), at: Date(timeIntervalSinceReferenceDate: .nan))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    private static func record() -> JournalRecord {
        JournalRecord(id: OperationID(), environmentID: EnvironmentID(), operation: .startEnvironment,
                      timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000), outcome: .started)
    }

    private static func record(matching record: JournalRecord, outcome: JournalRecord.Outcome) -> JournalRecord {
        JournalRecord(id: record.id, environmentID: record.environmentID, operation: record.operation,
                      timestamp: record.timestamp, outcome: outcome)
    }

    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var journal: URL { state.appending(path: "journal.ndjson") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-store-journal-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
        func open(hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(root: self.root) }, hooks: hooks)
        }
        func write(_ bytes: Data) throws {
            let fd = Darwin.open(journal.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try #require(fd >= 0)
            defer { close(fd) }
            try #require(fchmod(fd, 0o600) == 0)
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }
        func bytes() throws -> Data { try Data(contentsOf: journal) }
        func reattachJournal() throws {
            let detached = state.appending(path: "detached-journal"), evidence = try bytes()
            var before = stat()
            try #require(lstat(journal.path, &before) == 0)
            try #require(rename(journal.path, detached.path) == 0)
            let fd = Darwin.open(state.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try #require(fd >= 0)
            defer { close(fd) }
            try StateFileIO.fullySynchronize(fd, name: .stateDirectory)
            try #require(rename(detached.path, journal.path) == 0)
            var after = stat()
            try #require(lstat(journal.path, &after) == 0)
            try #require(StateFileIdentity(before) == StateFileIdentity(after))
            try #require(before.st_size == after.st_size)
            try #require(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                         && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            try #require(StateFileVersion(before) != StateFileVersion(after))
            try #require(bytes() == evidence)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
