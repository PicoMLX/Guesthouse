import Darwin
import Dispatch
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Actual actor composition of the retained #57 snapshot contracts, not just helper tests.
/// Every root is an isolated fixture; never call the default App Support factory here.
@Suite(.timeLimit(.minutes(1))) struct StateStoreSnapshotTests {
    @Test(arguments: [false, true])
    func staleOwnersCannotOverwritePeerPublications(initiallyPresent: Bool) async throws {
        let fixture = try Fixture(), first = try await fixture.open(), second = try await fixture.open()
        if initiallyPresent { try await first.saveSnapshot(sample()) }
        let baseline = try await first.loadSnapshot()
        #expect(try await second.loadSnapshot() == baseline)
        let winner = try sample(), loser = try sample()
        try await first.saveSnapshot(winner)
        let bytes = try fixture.bytes(), names = try fixture.names()
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
                try await second.saveSnapshot(loser)
            }
            #expect(try fixture.bytes() == bytes)
            #expect(try fixture.names() == names)
        }
        // Opening a new owner is not authority to overwrite an existing generation either.
        let fresh = try await fixture.open()
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try await fresh.saveSnapshot(loser)
        }
        #expect(try fixture.bytes() == bytes)
        #expect(try fixture.names() == names)
        // The caller explicitly inspects/reconciles before a subsequent replacement.
        #expect(try await second.loadSnapshot() == winner)
        try await second.saveSnapshot(loser)
        let replacement = try fixture.bytes()
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try await first.saveSnapshot(winner)
        }
        #expect(try fixture.bytes() == replacement)
        #expect(try await first.loadSnapshot() == loser)
    }

    @Test func failedPublicationDoesNotAdvanceTheOwnersExpectedVersion() async throws {
        let fixture = try Fixture(), initial = try await fixture.open(), baseline = try sample()
        try await initial.saveSnapshot(baseline)
        let barriers = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            let attempt = barriers.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw StateStoreError.fileUnwritable(name: .stateDirectory) }
            try StateFileIO.fullySynchronize(fd, name: name)
        }))
        #expect(try await store.loadSnapshot() == baseline)
        let published = try sample()
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) {
            try await store.saveSnapshot(published)
        }
        let evidence = try fixture.bytes(), names = try fixture.names()
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
                try await store.saveSnapshot(baseline)
            }
            #expect(try fixture.bytes() == evidence)
            #expect(try fixture.names() == names)
        }
        #expect(barriers.withLock { $0 } == 1)
        // Reading visible bytes is inspection, not proof that the failed save was durable.
        #expect(try await store.loadSnapshot() == published)
        try await store.saveSnapshot(baseline)
        #expect(barriers.withLock { $0 } == 2)
        #expect(try await store.loadSnapshot() == baseline)
    }

    @Test(arguments: [0, 1, 2, 3])
    func separateStoresShareSuccessfulAndFailedSnapshotObservations(scenario: Int) async throws {
        let fixture = try Fixture()
        let peer = try await fixture.open() // Open BEFORE the other actor observes anything.
        let first = try await fixture.open(hooks: scenario == 3
            ? StateStoreHooks(directory: { _, _ in throw StateStoreError.fileUnwritable(name: .stateDirectory) })
            : StateStoreHooks())
        switch scenario {
        case 0:
            try await first.saveSnapshot(.empty)
        case 1:
            try fixture.write(JSONEncoder().encode(EnvironmentsSnapshot.empty))
            #expect(try await first.loadSnapshot() == .empty)
        case 2:
            try fixture.write(Data("corrupt shared snapshot evidence".utf8))
            await #expect(throws: StateStoreError.corruptSnapshot) { try await first.loadSnapshot() }
        default:
            await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) {
                try await first.saveSnapshot(.empty)
            }
        }
        // This peer has never read/saved a snapshot itself.
        try await requireMissingSnapshotRefusal(peer, fixture: fixture)
        let later = try await fixture.open()
        await #expect(throws: StateStoreError.fileUnreadable(name: .snapshot)) { try await later.loadSnapshot() }
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await later.saveSnapshot(.empty) }
        let separateFixture = try Fixture(), separate = try await separateFixture.open()
        #expect(try await separate.loadSnapshot() == .empty)
        try await separate.saveSnapshot(.empty)
    }

    @Test func sharedObservationLivesUntilItsLastLeaseIsReleased() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: RuntimeStorage(root: fixture.root))
        let identity = try anchor.verifyCurrent().identity
        var first: StateSnapshotObservation? = StateSnapshotObservation(identity: identity)
        var peer: StateSnapshotObservation? = StateSnapshotObservation(identity: identity)
        weak let releasedFirst = first
        first?.record()
        first = nil
        #expect(releasedFirst == nil)
        #expect(peer?.wasObserved == true)
        var later: StateSnapshotObservation? = StateSnapshotObservation(identity: identity)
        #expect(later?.wasObserved == true)
        peer = nil
        #expect(later?.wasObserved == true)
        later = nil
        // Process-local evidence ends only with the last lease; a genuinely fresh owner
        // must inspect disk again. No reset API exists for a still-live owner.
        let fresh = StateSnapshotObservation(identity: identity)
        #expect(!fresh.wasObserved)
    }

    private func requireMissingSnapshotRefusal(_ store: StateStore, fixture: Fixture) async throws {
        let evidence = try fixture.bytes(), retained = fixture.state.appending(path: "retained-evidence")
        try #require(rename(fixture.snapshot.path, retained.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .snapshot)) { try await store.loadSnapshot() }
            await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await store.saveSnapshot(.empty) }
        }
        #expect(try fixture.names() == ["retained-evidence"])
        #expect(try Data(contentsOf: retained) == evidence)
    }

    @Test func openingAndMissingReadDoNotCreateStateFiles() async throws {
        let fixture = try Fixture()
        let barriers = Mutex<[StateStoreError.File]>([])
        let store = try await fixture.open(hooks: StateStoreHooks(preparation: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            barriers.withLock { $0.append(name) }
        }))
        #expect(barriers.withLock { !$0.isEmpty && $0.allSatisfy { $0 == .stateDirectory } })
        #expect(try await store.loadSnapshot() == .empty)
        #expect(try fixture.names().isEmpty)
    }

    @Test func snapshotRoundTripsAcrossReopeningWithExactDatesAndUUIDKeys() async throws {
        let fixture = try Fixture(), value = try sample()
        let store = try await fixture.open()
        try await store.saveSnapshot(value)
        #expect(try await store.loadSnapshot() == value)
        let reopened = try await fixture.open()
        #expect(try await reopened.loadSnapshot() == value)
        let json = try #require(JSONSerialization.jsonObject(with: fixture.bytes()) as? [String: Any])
        let provisioning = try #require(json["provisioning"] as? [String: Any])
        #expect(Set(provisioning.keys) == [value.environments[0].id.uuid.uuidString])
        #expect(json["schemaVersion"] as? Int == 2)
        #expect(try fixture.mode(fixture.state) == 0o700)
        #expect(try fixture.mode(fixture.snapshot) == 0o600)
    }

    private enum FixtureFailure: Error { case opaque }

    private func sample(date: Date = Date(timeIntervalSinceReferenceDate: 800_000_000.123456789)) throws -> EnvironmentsSnapshot {
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: date)
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        return EnvironmentsSnapshot(environments: [environment], slots: slots, provisioning: [environment.id: .initial])
    }

    private static func settingVersion(_ version: Int, in data: Data) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = version
        return try JSONSerialization.data(withJSONObject: object)
    }

    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var snapshot: URL { state.appending(path: "environments.json") }

        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-store-snapshots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }

        func open(migrator: SnapshotMigrator = .standard, hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(root: self.root) }, migrator: migrator, hooks: hooks)
        }
        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: state.path) }
        func bytes() throws -> Data { try Data(contentsOf: snapshot) }
        func write(_ bytes: Data) throws {
            try bytes.write(to: snapshot)
            try #require(chmod(snapshot.path, 0o600) == 0)
        }
        func mode(_ path: URL) throws -> mode_t {
            var info = stat()
            try #require(lstat(path.path, &info) == 0)
            return info.st_mode & 0o7777
        }
        func identity(_ path: URL) throws -> StateFileIdentity {
            var info = stat()
            try #require(lstat(path.path, &info) == 0)
            return StateFileIdentity(info)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
