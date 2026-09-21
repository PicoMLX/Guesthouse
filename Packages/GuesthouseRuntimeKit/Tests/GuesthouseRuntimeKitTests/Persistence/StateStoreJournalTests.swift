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

    @Test(arguments: [
        ("shrink", StateStoreError.fileUnreadable(name: .journal)),
        ("replace", .fileUnwritable(name: .journal)), ("rewrite", .fileUnreadable(name: .journal)),
    ])
    func observedHistoryCannotRollBackBetweenAppends(change: String, failure: StateStoreError) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        try await store.append(started)
        let original = try fixture.bytes()
        var changed = Data()
        if change == "replace" {
            try #require(rename(fixture.journal.path, fixture.state.appending(path: "retained").path) == 0)
            changed = original // Even byte-identical replacement loses the retained identity.
        } else if change == "rewrite" {
            changed = try JSONEncoder().encode(Self.record()) + Data([10])
        }
        try fixture.write(changed)
        for attempt in 0..<2 {
            await #expect(throws: attempt == 0 ? failure : StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: started.environmentID)
            }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(try fixture.bytes() == changed)
    }

    @Test func visibleUncertainAppendRemainsABaselineAfterFailure() async throws {
        let fixture = try Fixture(), fail = Mutex(false)
        let store = try await fixture.open(hooks: StateStoreHooks(journalFile: { fd, name in
            if fail.withLock({ $0 }) { throw StateStoreError.fileUnwritable(name: .journal) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }))
        let first = Self.record(), second = Self.record()
        try await store.append(first)
        let old = try fixture.bytes()
        fail.withLock { $0 = true }
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))) {
            try await store.append(second)
        }
        let evidence = try fixture.bytes()
        try #require(evidence.count > old.count)
        try fixture.write(old)
        fail.withLock { $0 = false }
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: second.environmentID)
            }
        }
        #expect(try fixture.bytes() == old)
        try fixture.write(evidence) // Restoration cannot erase the observed rollback.
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
            try await store.begin(.startEnvironment, for: second.environmentID)
        }
    }

    @Test(arguments: [false, true])
    func conflictingReadCannotBeForgottenAfterRestoration(throughAppend: Bool) async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let first = Self.record(), conflicting = Self.record()
        let original = try JSONEncoder().encode(first) + Data([10])
        let rewritten = try JSONEncoder().encode(conflicting) + Data([10])
        try fixture.write(original)
        _ = try await store.replay()
        try fixture.write(rewritten)
        if throughAppend {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        } else {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        try fixture.write(original)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: conflicting.environmentID)
            }
        }
        #expect(reads.withLock { $0 } == 2)
        #expect(try fixture.bytes() == original)
    }

    @Test(arguments: [false, true])
    func deniedJournalOpenCannotAuthorizeLaterCreation(throughReplay: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let evidence = try JSONEncoder().encode(Self.record()) + Data([10])
        try fixture.write(evidence)
        try #require(chmod(fixture.journal.path, 0) == 0)
        if throughReplay {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        } else {
            await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        }
        let retained = fixture.state.appending(path: "retained-evidence")
        try #require(rename(fixture.journal.path, retained.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        try #require(chmod(retained.path, 0o600) == 0)
        #expect(try Data(contentsOf: retained) == evidence)
    }

    @Test(arguments: [false, true])
    func missingObservedJournalCannotBeRecreatedAfterWriteOrReplay(throughReplay: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        if throughReplay {
            try fixture.write(JSONEncoder().encode(started) + Data([10]))
            _ = try await store.replay()
        } else { try await store.append(started) }
        let evidence = try fixture.bytes(), retained = fixture.state.appending(path: "retained")
        try #require(rename(fixture.journal.path, retained.path) == 0)
        for attempt in 0..<2 {
            await #expect(throws: attempt == 0 ? StateStoreError.fileUnwritable(name: .journal)
                          : StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: started.environmentID)
            }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        #expect(try Data(contentsOf: retained) == evidence)
    }

    @Test func failedAppendPreparationCannotAuthorizeJournalRecreation() async throws {
        let fixture = try Fixture()
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { _, _ in
            throw StateStoreError.fileUnwritable(name: .journal)
        }))
        let bytes = try JSONEncoder().encode(Self.record()) + Data([10])
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        let retained = fixture.state.appending(path: "retained")
        try #require(rename(fixture.journal.path, retained.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        #expect(try Data(contentsOf: retained) == bytes)
    }

    @Test(arguments: [false, true], ["write", "fileBarrier", "directoryBarrier"])
    func failedContentVerificationRemainsUnreadAfterRestoration(wrongLength: Bool, stage: String) async throws {
        let fixture = try Fixture(), first = try await fixture.open(), prior = Self.record(), next = Self.record()
        try await first.append(prior)
        let original = try fixture.bytes(), attempts = Mutex(0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(next) + Data([10])
        let conflicting = JournalRecord(id: OperationID(), environmentID: next.environmentID,
            operation: next.operation, timestamp: next.timestamp, outcome: next.outcome)
        let changed = try encoder.encode(conflicting) + Data([10])
        try #require(changed.count == expected.count && changed != expected)
        let substituted = wrongLength ? expected + Data([10]) : changed
        let alter: @Sendable () throws -> Void = { try fixture.write(original + substituted) }
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            if stage == "directoryBarrier" { try alter() }
        }, journalFile: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            if stage == "fileBarrier" { try alter() }
        }, journalWrite: { fd, bytes in
            attempts.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
            if stage == "write" { try alter() }
        }))
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))) {
            try await store.append(next)
        }
        #expect(try fixture.bytes() == original + substituted)
        // Restore before ANY replay; no subsequent parse/prefix failure may mask the check.
        try fixture.write(original)
        let later = try await fixture.open()
        for owner in [store, first, later] {
            for _ in 0..<2 {
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.append(next) }
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.replay() }
                #expect(try fixture.bytes() == original)
            }
        }
        #expect(attempts.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func competingAppendAfterSeekIsPreservedAndLatchesUncertainty(existing: Bool) async throws {
        let fixture = try Fixture(), first = try await fixture.open(), next = Self.record()
        if existing { try await first.append(Self.record()) }
        let original = existing ? try fixture.bytes() : Data(), attempts = Mutex(0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ownLine = try encoder.encode(next) + Data([10])
        let competing = JournalRecord(id: OperationID(), environmentID: next.environmentID,
            operation: next.operation, timestamp: next.timestamp, outcome: next.outcome)
        let otherLine = try encoder.encode(competing) + Data([10])
        try #require(otherLine.count == ownLine.count && otherLine != ownLine)
        let store = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            attempts.withLock { $0 += 1 }
            try #require(lseek(fd, 0, SEEK_CUR) == off_t(original.count))
            let other = Darwin.open(fixture.journal.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            try #require(other >= 0)
            defer { close(other) }
            // Deliberately ignore flock, after this transaction's final EOF seek.
            try StateFileIO.writeAll(other, otherLine, name: .journal)
            try #require(lseek(fd, 0, SEEK_CUR) == off_t(original.count))
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))) {
            try await store.append(next)
        }
        let retained = original + otherLine + ownLine
        #expect(try fixture.bytes() == retained)
        // Restore before any replay: the failed post-write check itself must be sticky.
        try fixture.write(original)
        let later = try await fixture.open()
        for owner in [store, first, later] {
            for _ in 0..<2 {
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.append(next) }
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.replay() }
                #expect(try fixture.bytes() == original)
            }
        }
        #expect(attempts.withLock { $0 } == 1)
    }

    @Test(arguments: ["write", "fileBarrier", "directoryBarrier"])
    func throwingMutationRetainsReplacedDirectoryUncertainty(stage: String) async throws {
        let fixture = try Fixture(), peer = try await fixture.open(), prior = Self.record(), next = Self.record()
        try await peer.append(prior)
        let original = try fixture.bytes(), writes = Mutex(0)
        let detached = fixture.base.appending(path: "detached-state")
        let conflicting = fixture.base.appending(path: "conflicting-state")
        let otherBytes = try JSONEncoder().encode(Self.record()) + Data([10])
        let failure = StateStoreError.fileUnwritable(name: .journal)
        let replaceAndFail: @Sendable () throws -> Void = {
            try FileManager.default.moveItem(at: fixture.state, to: detached)
            try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try fixture.write(otherBytes)
            throw failure
        }
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            if stage == "directoryBarrier" { try replaceAndFail() }
            try StateFileIO.fullySynchronize(fd, name: name)
        }, journalFile: { fd, name in
            if stage == "fileBarrier" { try replaceAndFail() }
            try StateFileIO.fullySynchronize(fd, name: name)
        }, journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            if stage == "write" { try replaceAndFail() }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: failure)) {
            try await store.append(next)
        }
        let retained = try Data(contentsOf: detached.appending(path: "journal.ndjson"))
        #expect(retained.starts(with: original))
        #expect(try fixture.bytes() == otherBytes)
        // Restore before any replay; a later failed inspection must not supply the latch.
        try FileManager.default.moveItem(at: fixture.state, to: conflicting)
        try FileManager.default.moveItem(at: detached, to: fixture.state)
        let later = try await fixture.open()
        for owner in [store, peer, later] {
            for _ in 0..<2 {
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.append(next) }
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.replay() }
                #expect(try fixture.bytes() == retained)
            }
        }
        #expect(try Data(contentsOf: conflicting.appending(path: "journal.ndjson")) == otherBytes)
        #expect(writes.withLock { $0 } == 1)
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

    @Test(arguments: [false, true])
    func peerCannotRecreateOrReplaceAnObservedJournal(replace: Bool) async throws {
        let fixture = try Fixture(), first = try await fixture.open(), writes = Mutex(0)
        let peer = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        let started = Self.record()
        try await first.append(started)
        let evidence = try fixture.bytes(), detached = fixture.base.appending(path: "retained")
        try #require(rename(fixture.journal.path, detached.path) == 0)
        if replace { try fixture.write(Data()) }
        for attempt in 0..<2 {
            let failure = attempt == 0 ? StateStoreError.fileUnwritable(name: .journal)
                : StateStoreError.fileUnreadable(name: .journal)
            await #expect(throws: failure) {
                try await peer.begin(.startEnvironment, for: started.environmentID)
            }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await first.replay()
            }
        }
        #expect(writes.withLock { $0 } == 0)
        #expect(try Data(contentsOf: detached) == evidence)
        if replace { #expect(try fixture.bytes().isEmpty) }
        else { #expect(!FileManager.default.fileExists(atPath: fixture.journal.path)) }
    }

    @Test func failedRequiredOpenRemainsUnreadAfterOriginalJournalReturns() async throws {
        let fixture = try Fixture(), first = try await fixture.open(), writes = Mutex(0)
        let peer = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        let started = Self.record()
        try await first.append(started)
        let original = try fixture.bytes(), detached = fixture.state.appending(path: "original")
        var before = stat(), restored = stat()
        try #require(lstat(fixture.journal.path, &before) == 0)
        try #require(rename(fixture.journal.path, detached.path) == 0)
        await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try await peer.append(Self.record(matching: started, outcome: .completed))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        // Do NOT replay the missing path here: that would independently latch uncertainty
        // and mask whether the failed required-existing append retained it.
        let hidden = try JSONEncoder().encode(Self.record()) + Data([10])
        try fixture.write(hidden)
        let hiddenJournal = fixture.state.appending(path: "hidden")
        try #require(rename(fixture.journal.path, hiddenJournal.path) == 0)
        try #require(rename(detached.path, fixture.journal.path) == 0)
        try #require(lstat(fixture.journal.path, &restored) == 0)
        #expect(StateFileIdentity(before) == StateFileIdentity(restored))
        let later = try await fixture.open()
        for owner in [peer, first, later] {
            for _ in 0..<2 {
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                    try await owner.append(Self.record(matching: started, outcome: .completed))
                }
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.replay() }
                #expect(try fixture.bytes() == original)
                #expect(try Data(contentsOf: hiddenJournal) == hidden)
            }
        }
        #expect(writes.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func tailRepairResultIsSharedWithAlreadyOpenPeers(failBarrier: Bool) async throws {
        let fixture = try Fixture(), peer = try await fixture.open(), started = Self.record()
        let writer = try await fixture.open(hooks: StateStoreHooks(journalFile: { fd, name in
            if failBarrier { throw StateStoreError.fileUnwritable(name: .journal) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }))
        let completed = Self.record(matching: started, outcome: .completed)
        let original = try JSONEncoder().encode(started) + Data([10]) + JSONEncoder().encode(completed).dropLast()
        try fixture.write(original)
        #expect(try await peer.replay().truncatedTail)
        if failBarrier {
            await #expect(throws: StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))) {
                try await writer.append(completed)
            }
            let preserved = try fixture.bytes()
            for owner in [peer, writer] {
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.replay() }
            }
            #expect(try fixture.bytes() == preserved)
        } else {
            try await writer.append(completed)
            for owner in [peer, writer] {
                let replay = try await owner.replay()
                #expect(replay.records == [started, completed] && !replay.truncatedTail && replay.inFlight.isEmpty)
            }
        }
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
        #expect(try await store.replay().records == [started, completed])
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

    @Test func partialWriteIsUncertainAndReplayPreservesItsTornEvidence() async throws {
        let fixture = try Fixture(), failure = StateStoreError.fileUnwritable(name: .journal)
        let store = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            try StateFileIO.writeAll(fd, Data(bytes.prefix(12)), name: .journal)
            throw failure
        }))
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: failure)) {
            try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        let evidence = try fixture.bytes(), replay = try await store.replay()
        #expect(evidence.count == 12 && replay.records.isEmpty && replay.truncatedTail)
        #expect(try fixture.bytes() == evidence)
    }

    @Test(arguments: [false, true])
    func substitutedObservedTailCannotAuthorizeAppend(truncate: Bool) async throws {
        let fixture = try Fixture(), writes = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        let started = Self.record(), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let prefix = try encoder.encode(started) + Data([10])
        let original = prefix + (try encoder.encode(Self.record())).dropLast()
        try fixture.write(original)
        #expect(try await store.replay().truncatedTail)
        let next = truncate ? prefix : prefix + (try encoder.encode(Self.record())) + Data([10])
        try fixture.write(next)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.append(Self.record(matching: started, outcome: .notApplied))
            }
        }
        #expect(writes.withLock { $0 } == 0)
        #expect(try fixture.bytes() == next)
    }

    @Test func failedAuthorizedTailRepairLeavesOwnerClosed() async throws {
        let fixture = try Fixture(), writes = Mutex(0)
        let failure = StateStoreError.fileUnwritable(name: .journal)
        let store = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, Data(bytes.prefix(12)), name: .journal)
            throw failure
        }))
        let started = Self.record()
        let original = try JSONEncoder().encode(started) + Data("\n{\"format\":".utf8)
        try fixture.write(original)
        #expect(try await store.replay().truncatedTail)
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: failure)) {
            try await store.append(Self.record(matching: started, outcome: .notApplied))
        }
        let visible = try fixture.bytes()
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        }
        #expect(try fixture.bytes() == visible)
        try fixture.write(original)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(writes.withLock { $0 } == 1)
        #expect(try fixture.bytes() == original)
    }

    @Test func sameLengthSubstitutionBeforeVersionCaptureNeverAuthorizesBegin() async throws {
        let fixture = try Fixture()
        let store = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            // Simulates a same-size replacement before the post-write version is captured.
            try StateFileIO.writeAll(fd, Data(repeating: 120, count: bytes.count), name: .journal)
        }))
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))) {
            try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        let evidence = try fixture.bytes()
        #expect(!evidence.isEmpty && evidence.allSatisfy { $0 == 120 })
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(try fixture.bytes() == evidence)
    }

    @Test(arguments: [false, true])
    func changedPriorHistoryBeforeVersionCaptureNeverAuthorizesBegin(validReplacement: Bool) async throws {
        let fixture = try Fixture(), initial = try await fixture.open(), started = Self.record()
        try await initial.append(started)
        let original = try fixture.bytes()
        var changed = original
        if validReplacement {
            // A different UUID preserves length and valid JSON while erasing an unresolved identity.
            let old = Data(started.id.uuid.uuidString.utf8)
            let range = try #require(changed.range(of: old))
            changed.replaceSubrange(range, with: Data(OperationID().uuid.uuidString.utf8))
        } else { changed[changed.startIndex] = 120 }
        let replacement = changed
        let store = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            let other = Darwin.open(fixture.journal.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            try #require(other >= 0)
            defer { close(other) }
            try #require(fcntl(other, F_GETFL) & O_APPEND == 0)
            try StateFileIO.writeAll(other, replacement, name: .journal)
            try #require(try fixture.bytes() == replacement)
            try StateFileIO.writeAll(fd, bytes, name: .journal)
            try #require(try fixture.bytes() == replacement + bytes)
        }))
        do {
            _ = try await store.begin(.startEnvironment, for: EnvironmentID())
            Issue.record("Changed prior history must not authorize a new operation")
        } catch {
            guard case .journalWriteUncertain = error else {
                Issue.record("A post-write refusal must report an uncertain outcome")
                return
            }
        }
        let evidence = try fixture.bytes()
        #expect(evidence.starts(with: replacement) && evidence.count > original.count)
        #expect(evidence != original)
    }

    @Test func extraBytesBeforeVersionCaptureNeverAuthorizeBegin() async throws {
        let fixture = try Fixture(), extra = Data("unparsed-evidence".utf8)
        let store = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            try StateFileIO.writeAll(fd, bytes + extra, name: .journal)
        }))
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))) {
            try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        let evidence = try fixture.bytes()
        #expect(evidence.suffix(extra.count) == extra)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
        #expect(try fixture.bytes() == evidence)
    }

    @Test(arguments: [false, true])
    func failedBarrierRequiresInspectionAndDoesNotAdoptCachedWrites(fileBarrier: Bool) async throws {
        let fixture = try Fixture(), fail = Mutex(true), reads = Mutex(0)
        let label: StateStoreError.File = fileBarrier ? .journal : .stateDirectory
        let failure = StateStoreError.fileUnwritable(name: label)
        let barrier: StateStoreHooks.Barrier = { fd, name in
            if name == label, fail.withLock({ $0 }) { throw failure }
            try StateFileIO.fullySynchronize(fd, name: name)
        }
        let store = try await fixture.open(hooks: StateStoreHooks(
            directory: barrier, journalFile: barrier, journalRead: { fd, offset in
                reads.withLock { $0 += 1 }
                return try StateFileIO.readAll(fd, from: offset, name: .journal)
            }))
        let environment = EnvironmentID()
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: failure)) {
            try await store.begin(.startEnvironment, for: environment)
        }
        let evidence = try fixture.bytes(), replay = try await store.replay()
        let started = try #require(replay.inFlight.values.first)
        #expect(reads.withLock { $0 } == 2)
        await #expect(throws: StateStoreError.operationUnresolved(started.id)) {
            try await store.begin(.startEnvironment, for: environment)
        }
        #expect(try fixture.bytes() == evidence)
        fail.withLock { $0 = false }
        try await store.append(Self.record(matching: started, outcome: .notApplied))
        #expect(try await store.replay().inFlight.isEmpty)
        #expect(try fixture.bytes().starts(with: evidence))
    }

    @Test(arguments: [false, true])
    func replacementDuringFinalBarrierNeverReturnsAuthorization(directory: Bool) async throws {
        let fixture = try Fixture(), detached = fixture.base.appending(path: "retained")
        let quarantined = fixture.base.appending(path: "conflicting"), conflicting = Self.record()
        let otherBytes = try JSONEncoder().encode(conflicting) + Data([10])
        let reads = Mutex(0), writes = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            if directory {
                try FileManager.default.moveItem(at: fixture.state, to: detached)
                try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
            } else {
                try FileManager.default.moveItem(at: fixture.journal, to: detached)
            }
            try fixture.write(otherBytes)
        }, journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }, journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        do {
            _ = try await store.begin(.startEnvironment, for: EnvironmentID())
            Issue.record("Replaced publication must not authorize an operation")
        } catch {
            guard case .journalWriteUncertain = error else {
                Issue.record("Post-write refusal must keep the uncertain outcome")
                return
            }
            #expect(error.recoveryActions.first == .inspectState)
        }
        let retained = directory ? detached.appending(path: "journal.ndjson") : detached
        let evidence = try Data(contentsOf: retained)
        #expect(!evidence.isEmpty)
        let reopened = try await fixture.open()
        if directory {
            // A genuinely different directory inode has an independent evidence lifetime.
            #expect(try await reopened.replay().records == [conflicting])
        } else {
            // Reopening the SAME directory must not forget another live owner's failed binding.
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await reopened.replay() }
        }
        let originalPath = directory ? fixture.state : fixture.journal
        try #require(rename(originalPath.path, quarantined.path) == 0)
        try #require(rename(detached.path, originalPath.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: conflicting.environmentID)
            }
        }
        #expect(reads.withLock { $0 } == 1 && writes.withLock { $0 } == 1)
        #expect(try fixture.bytes() == evidence)
        let otherPath = directory ? quarantined.appending(path: "journal.ndjson") : quarantined
        #expect(try Data(contentsOf: otherPath) == otherBytes)
    }

    @Test func reattachedJournalAndLaterConfirmedWritesAreReread() async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        try fixture.reattachJournal()
        let accepted = try await store.begin(.stopEnvironment, for: EnvironmentID())
        #expect(reads.withLock { $0 } == 2)
        _ = try await store.begin(.exportWork, for: EnvironmentID())
        #expect(reads.withLock { $0 } == 3)
        #expect(try await store.replay().inFlight[accepted]?.operation == .stopEnvironment)
    }

    @Test func sameInodeReattachmentAfterBarrierLeavesOwnerClosed() async throws {
        let fixture = try Fixture(), reads = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            try fixture.reattachJournal()
        }, journalRead: { fd, offset in
            reads.withLock { $0 += 1 }
            return try StateFileIO.readAll(fd, from: offset, name: .journal)
        }))
        let environment = EnvironmentID()
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))) {
            try await store.begin(.startEnvironment, for: environment)
        }
        let evidence = try fixture.bytes(), reopened = try await fixture.open()
        // Pure byte inspection does not reopen a poisoned owner or acknowledge durability.
        let replay = try JournalReplayChunk(evidence).history
        let uncertain = try #require(replay.inFlight.values.first)
        #expect(replay.records.count == 1 && uncertain.environmentID == environment)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await reopened.replay() }
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: environment)
            }
        }
        #expect(reads.withLock { $0 } == 1)
        #expect(try fixture.bytes() == evidence)
    }

    @Test func failedReplayBindingCannotAuthorizeAppendAfterRestoration() async throws {
        let fixture = try Fixture(), reads = Mutex(0), writes = Mutex(0)
        let detached = fixture.base.appending(path: "original")
        let quarantined = fixture.base.appending(path: "conflicting")
        let original = Self.record(), conflicting = Self.record()
        let bytes = try JSONEncoder().encode(original) + Data([0x0A])
        let otherBytes = try JSONEncoder().encode(conflicting) + Data([0x0A])
        let store = try await fixture.open(hooks: StateStoreHooks(journalRead: { fd, offset in
            let result = try StateFileIO.readAll(fd, from: offset, name: .journal)
            let attempt = reads.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                try #require(rename(fixture.state.path, detached.path) == 0)
                try #require(mkdir(fixture.state.path, 0o700) == 0)
                try fixture.write(otherBytes)
            }
            return result
        }, journalWrite: { fd, data in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, data, name: .journal)
        }))
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try await store.replay() }
        try #require(rename(fixture.state.path, quarantined.path) == 0)
        try #require(rename(detached.path, fixture.state.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: conflicting.environmentID)
            }
        }
        #expect(reads.withLock { $0 } == 1)
        #expect(writes.withLock { $0 } == 0)
        #expect(try fixture.bytes() == bytes)
        #expect(try Data(contentsOf: quarantined.appending(path: "journal.ndjson")) == otherBytes)
    }

    @Test func shorterAppendCannotEraseATailWhoseCompletionExceedsOriginalCapacity() async throws {
        let fixture = try Fixture(), writes = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        let start = Self.record()
        let longFinish = Self.record(matching: start,
            outcome: .failed(.unsupportedHost(.insufficientMemory(foundBytes: .max, minimumBytes: .max))))
        let shortFinish = Self.record(matching: start, outcome: .notApplied)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(start), completion = try encoder.encode(longFinish)
        let shortLine = try encoder.encode(shortFinish) + Data([10])
        let prefix = first + Data(repeating: 32,
            count: StateFileIO.maximumJournalBytes - completion.count - first.count - 1) + Data([10])
        let original = prefix + completion.dropLast()
        // The replacement fits; the observed record needs one byte more than the remaining
        // budget once its closing brace AND newline are counted. It must remain evidence.
        try StateJournalAppend.requireCapacity(bytes: prefix.count, records: 1, additionalBytes: shortLine.count)
        try fixture.write(original)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await store.append(shortFinish) }
            #expect(writes.withLock { $0 } == 0)
            #expect(try fixture.bytes() == original)
        }
        let reopened = try await fixture.open()
        await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await reopened.append(shortFinish) }
        #expect(try fixture.bytes() == original)
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
