import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Adapts retained #57 replay/recovery tests without pretending the pending append API exists.
@Suite(.timeLimit(.minutes(1))) struct StateStoreReplayTests {
    @Test func missingJournalReturnsEmptyWithoutCreatingFiles() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let replay = try await store.replay()
        #expect(replay.records.isEmpty && replay.inFlight.isEmpty && !replay.truncatedTail)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test(arguments: JournalOperation.allCases)
    func replayPreservesEveryOperationDetail(operation: JournalOperation) async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let started = Self.record(operation: operation)
        let completed = Self.record(id: started.id, environment: started.environmentID, operation: operation, outcome: .completed)
        let bytes = try Self.lines([started, completed])
        try fixture.write(bytes)
        let replay = try await store.replay()
        #expect(replay.records == [started, completed])
        #expect(replay.inFlight.isEmpty && !replay.truncatedTail)
        #expect(try fixture.bytes() == bytes)
    }

    @Test(arguments: [
        (JournalRecord.Outcome.unknown, true), (.failed(.canceled), true),
        (.completed, false), (.notApplied, false), (.failed(.runtimeMissing), false),
    ])
    func unresolvedAndSettledOutcomesStayDistinct(outcome: JournalRecord.Outcome, unresolved: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        let final = Self.record(id: started.id, environment: started.environmentID, outcome: outcome)
        try fixture.write(Self.lines([started, final]))
        let replay = try await store.replay()
        #expect(replay.records == [started, final])
        #expect((replay.inFlight[started.id] != nil) == unresolved)
    }

    @Test func unchangedConcurrentReplaysReuseOnlyTheValidatedCache() async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let record = Self.record()
        try fixture.write(Self.lines([record]))
        try await withThrowingTaskGroup(of: JournalReplay.self) { group in
            for _ in 0..<20 { group.addTask { try await store.replay() } }
            for try await replay in group { #expect(replay.records == [record]) }
        }
        #expect(reads.withLock { $0 } == 1)
    }

    @Test func equalSizeInPlaceRewriteInvalidatesCachedHistory() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let first = Self.record(), second = Self.record()
        let before = try Self.lines([first]), after = try Self.lines([second])
        try #require(before.count == after.count)
        try fixture.write(before)
        let identity = try fixture.identity(fixture.journal)
        #expect(try await store.replay().records == [first])
        try fixture.write(after)
        try #require(try fixture.identity(fixture.journal) == identity)
        #expect(try await store.replay().records == [second])
    }

    @Test func replacementAndShrinkDiscardTheOldHistory() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), first = Self.record(), second = Self.record()
        let original = try Self.lines([first])
        try fixture.write(original)
        #expect(try await store.replay().records == [first])
        let detached = fixture.state.appending(path: "retained")
        try #require(rename(fixture.journal.path, detached.path) == 0)
        try fixture.write(Self.lines([second]))
        #expect(try await store.replay().records == [second])
        try fixture.write(Data())
        let empty = try await store.replay()
        #expect(empty.records.isEmpty && empty.inFlight.isEmpty && !empty.truncatedTail)
        #expect(try Data(contentsOf: detached) == original)
    }

    @Test func missingFileClearsCachedRecordsAndDoesNotRecreateIt() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), record = Self.record()
        try fixture.write(Self.lines([record]))
        #expect(try await store.replay().records == [record])
        // Preserve the fixture under another name rather than deleting its evidence.
        try #require(rename(fixture.journal.path, fixture.state.appending(path: "retained").path) == 0)
        #expect(try await store.replay().records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func tornTailIsPreservedAndRereadFromItsFirstByte() async throws {
        let fixture = try Fixture(), offsets = Mutex<[off_t]>([])
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            offsets.withLock { $0.append(offset) }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let record = Self.record(), prefix = try Self.lines([record]), bytes = prefix + Data("{\"format\":".utf8)
        try fixture.write(bytes)
        let first = try await store.replay(), second = try await store.replay()
        #expect(first.records == [record] && second.records == [record])
        #expect(first.truncatedTail && second.truncatedTail)
        #expect(offsets.withLock { $0 } == [0, off_t(prefix.count)])
        #expect(try fixture.bytes() == bytes)
    }

    @Test func unchangedUnterminatedRecordKeepsItsSeparatorRequirement() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), record = Self.record()
        let bytes = try JSONEncoder().encode(record)
        try fixture.write(bytes)
        #expect(try await store.replay().records == [record])
        let fd = Darwin.open(fixture.journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let first = try StateJournalCache().refreshed(fd)
        let second = try first.refreshed(fd, read: { _, _ in
            Issue.record("Unchanged validated bytes were read again")
            return Data()
        })
        #expect(first.byteCount == bytes.count && second.byteCount == bytes.count)
        #expect(first.unterminatedRecord && second.unterminatedRecord)
        #expect(!second.truncatedTail && second.history.records == [record])
    }

    @Test(arguments: [
        ("{}", StateStoreError.corruptJournal(line: 1)),
        ("[]", .corruptJournal(line: 1)),
        ("null", .corruptJournal(line: 1)),
        ("false", .corruptJournal(line: 1)),
        ("{\"format\":0}", .corruptJournal(line: 1)),
        ("{\"format\":1}", .unsupportedJournalFormat(line: 1, format: 1)),
        ("{\"format\":99}", .unsupportedJournalFormat(line: 1, format: 99)),
    ])
    func completeInvalidFinalValuesAreNotTornWrites(raw: String, failure: StateStoreError) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), bytes = Data(raw.utf8)
        try fixture.write(bytes)
        await #expect(throws: failure) { try await store.replay() }
        await #expect(throws: failure) { try await store.replay() }
        #expect(try fixture.bytes() == bytes)
    }

    @Test func corruptMiddleLineRefusesTheWholeReplayWithoutChangingEvidence() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), record = Self.record()
        let bytes = try Self.lines([record]) + Data("not JSON\n".utf8) + Self.lines([Self.record()])
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await store.replay() }
        #expect(try fixture.bytes() == bytes)
    }

    @Test func contradictoryCompleteFinalRecordCannotExposeAPartialHistory() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), record = Self.record()
        let bytes = try Self.lines([record]) + JSONEncoder().encode(record)
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await store.replay() }
        #expect(try fixture.bytes() == bytes)
    }

    @Test func failedPermissionCheckInvalidatesAnOtherwiseUnchangedCache() async throws {
        let fixture = try Fixture(), fail = Mutex(false), reads = Mutex(0)
        let failure = StateStoreError.fileUnwritable(name: .journal)
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { fd, name in
            if fail.withLock({ $0 }) { throw failure }
            try StateFileIO.fullySynchronize(fd, name: name)
        }, journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let record = Self.record()
        try fixture.write(Self.lines([record]))
        #expect(try await store.replay().records == [record])
        fail.withLock { $0 = true }
        await #expect(throws: failure) { try await store.replay() }
        fail.withLock { $0 = false }
        #expect(try await store.replay().records == [record])
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func opaqueReadFailureIsClosedAndDoesNotPoisonTheNextReplay() async throws {
        enum Failure: Error { case opaque }
        let fixture = try Fixture(), attempts = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw Failure.opaque }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let record = Self.record(), bytes = try Self.lines([record])
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(try await store.replay().records == [record])
        #expect(attempts.withLock { $0 } == 2)
        #expect(try fixture.bytes() == bytes)
    }

    @Test func postReadFileReattachmentRefusesAndDiscardsTheCandidate() async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let target = fixture.journal, detached = fixture.base.appending(path: "detached")
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            let bytes = try StateFileIO.readAll(fd, from: offset, name: .journal)
            let attempt = reads.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                let identity = try fixture.identity(target)
                try #require(rename(target.path, detached.path) == 0)
                try #require(rename(detached.path, target.path) == 0)
                try #require(try fixture.identity(target) == identity)
            }
            return bytes
        }))
        let record = Self.record(), bytes = try Self.lines([record])
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) { try await store.replay() }
        #expect(try await store.replay().records == [record])
        #expect(reads.withLock { $0 } == 2)
        #expect(try fixture.bytes() == bytes)
    }

    @Test func directoryReplacementAfterReadingCannotPublishACachedCandidate() async throws {
        let fixture = try Fixture(), reads = Mutex(0), detached = fixture.base.appending(path: "detached")
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            let bytes = try StateFileIO.readAll(fd, from: offset, name: .journal)
            let attempt = reads.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                try #require(rename(fixture.state.path, detached.path) == 0)
                try #require(mkdir(fixture.state.path, 0o700) == 0)
            }
            return bytes
        }))
        let record = Self.record(), bytes = try Self.lines([record])
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try await store.replay() }
        #expect(try Data(contentsOf: detached.appending(path: "journal.ndjson")) == bytes)
        // Restore the retained fixture. Its file version is unchanged: a prematurely
        // adopted candidate would now suppress the required read and fail the count.
        try #require(rmdir(fixture.state.path) == 0)
        try #require(rename(detached.path, fixture.state.path) == 0)
        #expect(try await store.replay().records == [record])
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func fifoJournalIsRefusedWithoutWaitingForAWriter() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        try #require(mkfifo(fixture.journal.path, 0o600) == 0)
        await #expect(throws: StateStoreError.insecureDirectory(reason: .notRegularFile)) { try await store.replay() }
    }

    private static func record(
        id: OperationID = OperationID(), environment: EnvironmentID = EnvironmentID(),
        operation: JournalOperation = .startEnvironment, outcome: JournalRecord.Outcome = .started
    ) -> JournalRecord {
        JournalRecord(id: id, environmentID: environment, operation: operation,
                      timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000), outcome: outcome)
    }

    private static func lines(_ records: [JournalRecord]) throws -> Data {
        var bytes = Data()
        for record in records {
            bytes.append(try JSONEncoder().encode(record))
            bytes.append(0x0A)
        }
        return bytes
    }

    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var journal: URL { state.appending(path: "journal.ndjson") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-store-replay-\(UUID().uuidString)")
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
        func identity(_ path: URL) throws -> StateFileIdentity {
            var info = stat()
            try #require(lstat(path.path, &info) == 0)
            return StateFileIdentity(info)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
