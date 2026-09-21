import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Adapts retained #57 replay/recovery tests without pretending the pending append API exists.
@Suite(.timeLimit(.minutes(1))) struct StateStoreReplayTests {
    @Test(arguments: [false, true])
    func unreadBorrowCannotBeClearedByMissingOrNewIdentity(wasIdentified: Bool) throws {
        var info = stat()
        info.st_dev = 1; info.st_ino = 1
        let original = StateFileIdentity(info)
        info.st_ino = 2
        let replacement = StateFileIdentity(info)
        var failed = StateJournalObservation()
        if wasIdentified { try #require(failed.identify(original)) }
        failed.recordUnreadFailure()
        #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try failed.requireReadable() }
        for identity in [nil, original, replacement] as [StateFileIdentity?] {
            // Independent copies prevent identify(nil)'s unbound latch from masking
            // a later identity transition that accidentally clears unread evidence.
            var observation = failed
            _ = observation.identify(identity)
            #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try observation.requireReadable() }
            _ = observation.identify(original)
            for _ in 0..<2 {
                #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                    try observation.requireReadable()
                }
            }
        }
    }

    @Test func budgetCountsFinalLinesBeforeDecoding() throws {
        let exact = Data(repeating: 10, count: StateJournalCache.maximumRecords)
        try StateJournalCache.validateBudget(exact)
        for bytes in [exact + Data([10]), exact + Data([123]),
                      Data(repeating: 0, count: StateFileIO.maximumJournalBytes + 1)] {
            #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try StateJournalCache.validateBudget(bytes)
            }
        }
    }

    @Test(arguments: [false, true])
    func tornCompletionMustFitTheRemainingFileBudget(fits: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), start = Self.record()
        let finish = Self.record(id: start.id, environment: start.environmentID,
            outcome: .failed(.unsupportedHost(.insufficientMemory(foundBytes: .max, minimumBytes: .max))))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(start), completion = try encoder.encode(finish)
        let remaining = completion.count + (fits ? 1 : 0)
        let prefix = first + Data(repeating: 32,
            count: StateFileIO.maximumJournalBytes - remaining - first.count - 1) + Data([10])
        let bytes = prefix + completion.dropLast()
        try fixture.write(bytes)
        for _ in 0..<2 {
            if fits {
                let replay = try await store.replay()
                #expect(replay.records == [start] && replay.truncatedTail)
            } else {
                await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await store.replay() }
            }
            #expect(try fixture.bytes() == bytes)
        }
    }

    @Test func oversizedJournalRefusesBeforeCallingTheReader() async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { _, _ in
            reads.withLock { $0 += 1 }; return Data()
        }))
        try fixture.write(Data())
        let fd = Darwin.open(fixture.journal.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(ftruncate(fd, off_t(StateFileIO.maximumJournalBytes + 1)) == 0)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(reads.withLock { $0 } == 0)
        var info = stat()
        try #require(fstat(fd, &info) == 0)
        #expect(info.st_size == off_t(StateFileIO.maximumJournalBytes + 1))
    }

    @Test func injectedOversizedReadCannotBypassBudget() async throws {
        let fixture = try Fixture()
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { _, _ in
            Data(repeating: 0, count: StateFileIO.maximumJournalBytes + 1)
        }))
        let original = try Self.lines([Self.record()])
        try fixture.write(original)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(try fixture.bytes() == original)
    }

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

    @Test func concurrentReplaysEachRevalidateLockedContents() async throws {
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
        #expect(reads.withLock { $0 } == 20)
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
        #expect(offsets.withLock { $0 } == [0, 0])
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
        let second = try first.refreshed(fd)
        #expect(first.byteCount == bytes.count && second.byteCount == bytes.count)
        #expect(first.unterminatedRecord && second.unterminatedRecord)
        #expect(!second.truncatedTail && second.history.records == [record])
    }

    @Test func equalMetadataDoesNotAuthenticateCachedContents() throws {
        let fixture = try Fixture()
        _ = try RuntimeStorage(root: fixture.root)
        let firstRecord = Self.record(), secondRecord = Self.record()
        let firstBytes = try Self.lines([firstRecord]), secondBytes = try Self.lines([secondRecord])
        try #require(firstBytes.count == secondBytes.count)
        try fixture.write(firstBytes)
        let fd = Darwin.open(fixture.journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let first = try StateJournalCache().refreshed(fd)
        let second = try first.refreshed(fd, read: { _, offset in
            #expect(offset == 0)
            return secondBytes // A different read with the exact same fstat metadata.
        })
        #expect(first.file == second.file && first.byteCount == second.byteCount)
        #expect(second.history.records == [secondRecord])
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
