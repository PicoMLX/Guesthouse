import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Adapts retained #57 replay/recovery tests without pretending the pending append API exists.
@Suite(.timeLimit(.minutes(1))) struct StateStoreReplayTests {
    @Test(arguments: [false, true], [false, true])
    func preBorrowDirectoryFailureRemainsClosedAfterRestoration(priorRead: Bool, initiallyMissing: Bool) async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let original = try Self.lines([Self.record()]), other = try Self.lines([Self.record()])
        if !initiallyMissing { try fixture.write(original) }
        if priorRead { _ = try await store.replay() }
        let detached = fixture.base.appending(path: "retained-directory")
        let conflicting = fixture.base.appending(path: "conflicting-directory")
        try #require(rename(fixture.state.path, detached.path) == 0)
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        try fixture.write(other)
        await #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try await store.replay() }
        try #require(rename(fixture.state.path, conflicting.path) == 0)
        try #require(rename(detached.path, fixture.state.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(reads.withLock { $0 } == (priorRead && !initiallyMissing ? 1 : 0))
        if initiallyMissing { #expect(!FileManager.default.fileExists(atPath: fixture.journal.path)) }
        else { #expect(try fixture.bytes() == original) }
        #expect(try Data(contentsOf: conflicting.appending(path: "journal.ndjson")) == other)
    }

    @Test(arguments: [false, true])
    func firstPreparationFailureCannotAcceptSameInodeChanges(truncate: Bool) async throws {
        let fixture = try Fixture(), fail = Mutex(true), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { fd, name in
            if fail.withLock({ $0 }) { throw StateStoreError.fileUnwritable(name: .journal) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }, journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        try fixture.write(Self.lines([Self.record()]))
        let identity = try fixture.identity(fixture.journal)
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) { try await store.replay() }
        let changed = truncate ? Data() : try Self.lines([Self.record()])
        try fixture.write(changed)
        try #require(try fixture.identity(fixture.journal) == identity)
        fail.withLock { $0 = false }
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(reads.withLock { $0 } == 0)
        #expect(try fixture.bytes() == changed)
    }

    @Test(arguments: [false, true])
    func shortFirstReadCannotPublishEmptyHistory(truncateFile: Bool) async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { _, _ in
            reads.withLock { $0 += 1 }
            if truncateFile { try fixture.write(Data()) }
            return Data()
        }))
        let original = try Self.lines([Self.record()])
        try fixture.write(original)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(reads.withLock { $0 } == 1)
        #expect(try fixture.bytes() == (truncateFile ? Data() : original))
    }

    @Test func firstCorruptReplayPinsItsWholeEvidenceBeforeDecoding() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let original = try Self.lines([Self.record()]) + Data("not JSON\n".utf8)
        try fixture.write(original)
        await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await store.replay() }
        try fixture.write(Data())
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(try fixture.bytes().isEmpty)
        try fixture.write(original)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(try fixture.bytes() == original)
    }

    @Test(arguments: [false, true])
    func firstPreBodyFailurePinsIdentityBeforeReplacement(deniedOpen: Bool) async throws {
        let fixture = try Fixture(), fail = Mutex(!deniedOpen)
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { fd, name in
            if fail.withLock({ $0 }) { throw StateStoreError.fileUnwritable(name: .journal) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }))
        let original = try Self.lines([Self.record()])
        try fixture.write(original)
        if deniedOpen { try #require(chmod(fixture.journal.path, 0) == 0) }
        await #expect(throws: StateStoreError.self) { try await store.replay() }
        let retained = fixture.state.appending(path: "retained-original")
        try #require(rename(fixture.journal.path, retained.path) == 0)
        try fixture.write(Data())
        fail.withLock { $0 = false }
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(try fixture.bytes().isEmpty)
        try #require(chmod(retained.path, 0o600) == 0)
        #expect(try Data(contentsOf: retained) == original)
    }

    @Test func unknownEntryBindingCannotBecomeANewIdentity() throws {
        let fixture = try Fixture()
        _ = try RuntimeStorage(root: fixture.root)
        try fixture.write(Data())
        var observation = StateJournalObservation()
        #expect(!observation.identify(nil))
        #expect(!observation.identify(try fixture.identity(fixture.journal)))
    }

    @Test func deniedJournalOpenThenDisappearanceCannotBecomeEmpty() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let evidence = try Self.lines([Self.record()])
        try fixture.write(evidence)
        try #require(chmod(fixture.journal.path, 0) == 0)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        var info = stat()
        try #require(lstat(fixture.journal.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0)
        let retained = fixture.state.appending(path: "retained-evidence")
        try #require(rename(fixture.journal.path, retained.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        try #require(chmod(retained.path, 0o600) == 0)
        #expect(try Data(contentsOf: retained) == evidence)
    }

    @Test func unreadBorrowCannotBeClearedByMissingOrNewIdentity() throws {
        var observation = StateJournalObservation()
        observation.recordUnreadFailure()
        for _ in 0..<2 {
            #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try observation.requireReadable()
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

    @Test func equalSizeInPlaceRewriteCannotEraseObservedHistory() async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let first = Self.record(), second = Self.record()
        let before = try Self.lines([first]), after = try Self.lines([second])
        try #require(before.count == after.count)
        try fixture.write(before)
        let identity = try fixture.identity(fixture.journal)
        #expect(try await store.replay().records == [first])
        try fixture.write(after)
        try #require(try fixture.identity(fixture.journal) == identity)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(try fixture.bytes() == after)
        try fixture.write(before)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(reads.withLock { $0 } == 2)
        #expect(try fixture.bytes() == before)
    }

    @Test func replacementAndShrinkCannotEraseObservedHistory() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), first = Self.record(), second = Self.record()
        let original = try Self.lines([first])
        try fixture.write(original)
        #expect(try await store.replay().records == [first])
        let detached = fixture.state.appending(path: "retained")
        try #require(rename(fixture.journal.path, detached.path) == 0)
        try fixture.write(Self.lines([second]))
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        try fixture.write(Data())
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(try fixture.bytes().isEmpty)
        #expect(try Data(contentsOf: detached) == original)
    }

    @Test(arguments: [false, true])
    func priorHistorySurvivesReadAndParseFailures(parseFailure: Bool) async throws {
        let fixture = try Fixture(), fail = Mutex(false)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            if fail.withLock({ $0 }) { throw StateStoreError.fileUnreadable(name: .journal) }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let first = Self.record(), second = Self.record()
        let prefix = try Self.lines([first]), full = try prefix + Self.lines([second])
        try fixture.write(full)
        #expect(try await store.replay().records == [first, second])
        if parseFailure { try fixture.write(full + Data("not JSON\n".utf8)) }
        else { fail.withLock { $0 = true } }
        await #expect(throws: StateStoreError.self) { try await store.replay() }
        fail.withLock { $0 = false }
        try fixture.write(prefix)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(try fixture.bytes() == prefix)
        if parseFailure {
            // A failed complete parse pins even the corrupt suffix. Once a non-prefix
            // read is observed, restoring any earlier bytes cannot clear uncertainty.
            let corrupt = full + Data("not JSON\n".utf8)
            try fixture.write(corrupt)
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
            #expect(try fixture.bytes() == corrupt)
            return
        }
        // Failed I/O may have hidden newer evidence; restoring an older prefix is not proof.
        try fixture.write(full)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        let third = Self.record()
        try fixture.write(full + Self.lines([third]))
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
    }

    @Test(arguments: [JournalRecord.Outcome.started, .checkpoint(.preflight), .unknown])
    func missingObservedJournalRefusesRepeatedReads(outcome: JournalRecord.Outcome) async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let started = Self.record(operation: .provision(stage: .preflight))
        let latest = Self.record(id: started.id, environment: started.environmentID,
                                 operation: started.operation, outcome: outcome)
        let records = outcome == .started ? [started] : [started, latest]
        let bytes = try Self.lines(records)
        try fixture.write(bytes)
        #expect(try await store.replay().records == records)
        // Preserve the fixture under another name rather than deleting its evidence.
        try #require(rename(fixture.journal.path, fixture.state.appending(path: "retained").path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        #expect(try Data(contentsOf: fixture.state.appending(path: "retained")) == bytes)
    }

    @Test func preBodyFailureStillRecordsJournalObservation() async throws {
        let fixture = try Fixture()
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { _, _ in
            throw StateStoreError.fileUnwritable(name: .journal)
        }))
        let bytes = try Self.lines([Self.record()])
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) { try await store.replay() }
        let retained = fixture.state.appending(path: "retained")
        try #require(rename(fixture.journal.path, retained.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(try Data(contentsOf: retained) == bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    @Test func failedParseDoesNotEraseJournalObservation() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        try fixture.write(Data("not json".utf8))
        await #expect(throws: StateStoreError.corruptJournal(line: 1)) { try await store.replay() }
        try #require(rename(fixture.journal.path, fixture.state.appending(path: "retained").path) == 0)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
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

    @Test(arguments: ["truncate", "replace", "extend"])
    func observedTornSuffixCannotBeSubstitutedByOrdinaryReplay(change: String) async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let prior = Self.record(), partial = Self.record(), prefix = try Self.lines([prior])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let complete = try encoder.encode(partial)
        let original = prefix + complete.dropLast()
        try fixture.write(original)
        let identity = try fixture.identity(fixture.journal)
        let first = try await store.replay()
        #expect(first.records == [prior] && first.truncatedTail)
        let next = change == "truncate" ? prefix : change == "replace"
            ? prefix + (try Self.lines([Self.record()])) : prefix + complete + Data([10])
        try fixture.write(next)
        #expect(try fixture.identity(fixture.journal) == identity)
        if change == "extend" {
            let replay = try await store.replay()
            #expect(replay.records == [prior, partial] && !replay.truncatedTail)
        } else {
            for _ in 0..<2 {
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
            }
            #expect(try fixture.bytes() == next)
            try fixture.write(original)
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(reads.withLock { $0 } == 2)
        #expect(try fixture.bytes() == (change == "extend" ? next : original))
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
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(reads.withLock { $0 } == 1)
    }

    @Test(arguments: ["unchanged", "truncate", "rewrite"])
    func initialReadFailureRemainsUncertainAfterSameInodeChanges(change: String) async throws {
        enum Failure: Error { case opaque }
        let fixture = try Fixture(), attempts = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw Failure.opaque }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let record = Self.record(), bytes = try Self.lines([record])
        try fixture.write(bytes)
        let identity = try fixture.identity(fixture.journal)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        let next = change == "truncate" ? Data() : change == "rewrite" ? try Self.lines([Self.record()]) : bytes
        try fixture.write(next)
        try #require(try fixture.identity(fixture.journal) == identity)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(attempts.withLock { $0 } == 1)
        #expect(try fixture.bytes() == next)
    }

    @Test func postReadFileReattachmentKeepsTheOwnerUnread() async throws {
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
        do {
            _ = try await store.replay()
            Issue.record("Reattachment must reject the first read or its outer binding check")
        } catch {
            // A changed descriptor version can fail the read-consistency check first;
            // otherwise the following entry/directory check reports the original failure.
            #expect(error == .fileUnreadable(name: .journal)
                    || error == .fileUnwritable(name: .journal)
                    || error == .insecureDirectory(reason: .changed))
        }
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(reads.withLock { $0 } == 1)
        #expect(try fixture.bytes() == bytes)
    }

    @Test func directoryReplacementAfterReadingCannotPublishACachedCandidate() async throws {
        let fixture = try Fixture(), reads = Mutex(0), detached = fixture.base.appending(path: "detached")
        let conflicting = try Self.lines([Self.record()])
        let quarantined = fixture.base.appending(path: "conflicting")
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            let bytes = try StateFileIO.readAll(fd, from: offset, name: .journal)
            let attempt = reads.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                try #require(rename(fixture.state.path, detached.path) == 0)
                try #require(mkdir(fixture.state.path, 0o700) == 0)
                try fixture.write(conflicting)
            }
            return bytes
        }))
        let record = Self.record(), bytes = try Self.lines([record])
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try await store.replay() }
        #expect(try Data(contentsOf: detached.appending(path: "journal.ndjson")) == bytes)
        // Restoring the original path cannot disprove the conflicting operation.
        // Keep both pieces of evidence; this owner must not perform another read.
        try #require(rename(fixture.state.path, quarantined.path) == 0)
        try #require(rename(detached.path, fixture.state.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(reads.withLock { $0 } == 1)
        #expect(try fixture.bytes() == bytes)
        #expect(try Data(contentsOf: quarantined.appending(path: "journal.ndjson")) == conflicting)
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
