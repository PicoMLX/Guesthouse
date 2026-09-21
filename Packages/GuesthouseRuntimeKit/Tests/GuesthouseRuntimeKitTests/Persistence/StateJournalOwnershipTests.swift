import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct StateJournalOwnershipTests {
    @Test func leasesKeepFailuresUntilTheLastOwnerLeaves() throws {
        let fixture = try Fixture()
        let identity = try fixture.identity()
        var first: StateJournalOwnership? = StateJournalOwnership(identity: identity)
        var second: StateJournalOwnership? = StateJournalOwnership(identity: identity)
        try #require(first).withObservation { observation, observed in
            observed = true
            observation.recordUnreadFailure()
        }
        first = nil
        let later = StateJournalOwnership(identity: identity)
        for owner in [try #require(second), later] {
            try owner.withObservation { (observation, observed) throws(StateStoreError) in
                #expect(observed)
                #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                    try observation.requireReadable()
                }
            }
        }
        second = nil
        // A nested borrow proves the registry lock is not held during callbacks; refusing
        // that borrow must neither run its body nor poison the successful outer transaction.
        try later.withObservation { (observation, observed) throws(StateStoreError) in
            #expect(observed)
            #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                try later.withObservation { _, _ in Issue.record("Contending body ran") }
            }
            #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try observation.requireReadable()
            }
        }
    }

    @Test func lastLeaseReleaseIsNotAPersistentResetAPI() throws {
        let fixture = try Fixture(), identity = try fixture.identity()
        do {
            let owner = StateJournalOwnership(identity: identity)
            try owner.withObservation { observation, observed in
                observed = true
                observation.recordUnreadFailure()
            }
        }
        // Only in-memory evidence expires. A subsequent store still has to inspect disk.
        let nextLifetime = StateJournalOwnership(identity: identity)
        try nextLifetime.withObservation { (observation, observed) throws(StateStoreError) in
            #expect(!observed)
            try observation.requireReadable()
        }
    }

    @Test func contentionDoesNotPoisonAndOtherDirectoriesRemainIndependent() throws {
        let fixture = try Fixture(), other = try Fixture()
        let owner = StateJournalOwnership(identity: try fixture.identity())
        let peer = StateJournalOwnership(identity: try fixture.identity())
        let independent = StateJournalOwnership(identity: try other.identity())
        #expect(throws: StateStoreError.corruptJournal(line: 1)) {
            try owner.withObservation { (observation, observed) throws(StateStoreError) in
                observed = true
                #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                    try peer.withObservation { _, _ in Issue.record("Contending body ran") }
                }
                try independent.withObservation { (value, seen) throws(StateStoreError) in
                    #expect(!seen)
                    try value.requireReadable()
                }
                try observation.requireReadable()
                throw .corruptJournal(line: 1)
            }
        }
        try peer.withObservation { (observation, observed) throws(StateStoreError) in
            #expect(observed) // Failure still writes back the observation.
            try observation.requireReadable() // Ordinary contention did not poison it.
        }
    }

    @Test(arguments: [false, true])
    func peersRetainObservedMissingOrReplacedJournal(replace: Bool) async throws {
        let fixture = try Fixture(), first = try await fixture.open(), peer = try await fixture.open()
        let original = try Self.bytes(), replacement = try Self.bytes()
        try fixture.write(original)
        #expect(try await first.replay().records.count == 1)
        let detached = fixture.state.appending(path: "retained")
        try #require(rename(fixture.journal.path, detached.path) == 0)
        if replace { try fixture.write(replacement) }
        let later = try await fixture.open()
        for owner in [peer, later, first] {
            for _ in 0..<2 {
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.replay() }
            }
        }
        #expect(try Data(contentsOf: detached) == original)
        if replace { #expect(try Data(contentsOf: fixture.journal) == replacement) }
        else { #expect(!FileManager.default.fileExists(atPath: fixture.journal.path)) }
    }

    @Test func peersRetainSameInodePrefixAndFailedReadEvidence() async throws {
        let fixture = try Fixture(), first = try await fixture.open(), peer = try await fixture.open()
        let original = try Self.bytes(), replacement = try Self.bytes()
        try fixture.write(original)
        #expect(try await first.replay().records.count == 1)
        let identity = try fixture.identity(fixture.journal)
        try fixture.write(replacement)
        #expect(try fixture.identity(fixture.journal) == identity)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await peer.replay() }
        try fixture.write(original)
        for owner in [first, peer] {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.replay() }
        }
        #expect(try Data(contentsOf: fixture.journal) == original)
    }

    @Test func initialReadFailureIsSharedBeforeAnySuccessfulReplay() async throws {
        let fixture = try Fixture()
        let first = try await fixture.open(hooks: StateStoreHooks(journalRead: { _, _ in
            throw StateStoreError.fileUnreadable(name: .journal)
        }))
        let peer = try await fixture.open(), original = try Self.bytes()
        try fixture.write(original)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await first.replay() }
        for owner in [peer, first] {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await owner.replay() }
        }
        #expect(try Data(contentsOf: fixture.journal) == original)
    }

    private static func bytes() throws -> Data {
        let record = JournalRecord(id: OperationID(), environmentID: EnvironmentID(), operation: .startEnvironment,
                                   timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000), outcome: .started)
        return try JSONEncoder().encode(record) + Data([10])
    }
    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var journal: URL { state.appending(path: "journal.ndjson") }
        init() throws {
            var template = Array("/private/tmp/guesthouse-journal-ownership-XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else { throw StorageFailure.inspectionFailed }
            base = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func identity(_ path: URL? = nil) throws -> StateFileIdentity {
            var info = stat()
            try #require(lstat((path ?? base).path, &info) == 0)
            return StateFileIdentity(info)
        }
        func open(hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(root: self.root) }, hooks: hooks)
        }
        func write(_ bytes: Data) throws {
            let fd = Darwin.open(journal.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try #require(fd >= 0)
            defer { close(fd) }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }
    }
}
