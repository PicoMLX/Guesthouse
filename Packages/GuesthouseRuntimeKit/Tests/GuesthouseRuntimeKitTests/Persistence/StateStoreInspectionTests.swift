import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct StateStoreInspectionTests {
    @Test(arguments: [false, true]) func absentRootDoesNotPrepareAnyDirectories(nested: Bool) throws {
        let fixture = try Fixture()
        let root = nested ? fixture.base.appending(path: "missing/Guesthouse") : fixture.root
        #expect(try StateStore.inspectSnapshot(storage: { try RuntimeStorage.existing(root: root) }) == .empty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).isEmpty)
    }

    @Test func absentSnapshotDoesNotCreateFilesOrSynchronizeMetadata() throws {
        let fixture = try Fixture()
        _ = try RuntimeStorage(root: fixture.root)
        let before = try fixture.version(fixture.state)
        #expect(try fixture.inspect() == .empty)
        #expect(try fixture.version(fixture.state) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test func persistedSnapshotIsReadWithoutPreparingAStoreAgain() async throws {
        let fixture = try Fixture()
        let environment = DevelopmentEnvironment(name: "Retained work")
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let value = EnvironmentsSnapshot(environments: [environment], slots: slots,
                                         provisioning: [environment.id: .initial])
        let store = try await StateStore.open(storage: { try RuntimeStorage(root: fixture.root) })
        try await store.saveSnapshot(value)
        let before = try fixture.version(fixture.snapshot), bytes = try Data(contentsOf: fixture.snapshot)
        #expect(try fixture.inspect() == value)
        #expect(try fixture.version(fixture.snapshot) == before)
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
    }

    @Test func verifyOnlyAccessRetainsReadFlagsAndLockWithoutCallingABarrier() throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let storage = try #require(RuntimeStorage.existing(root: fixture.root))
        let anchor = try StateDirectoryAnchor(storage: storage)
        let before = try fixture.version(fixture.snapshot)
        let bytes = try anchor.withFile(.readSnapshot, protection: .verifyOnly,
            permissionBarrier: { _, _ in Issue.record("Read-only inspection invoked a write barrier") }) { fd in
                #expect(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY)
                #expect(fcntl(fd, F_GETFL) & O_NONBLOCK != 0)
                #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
                let other = open(fixture.snapshot.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                try #require(other >= 0)
                defer { close(other) }
                #expect(flock(other, LOCK_EX | LOCK_NB) == -1)
                return try StateFileIO.readAll(fd, from: 0, name: .snapshot)
            }
        #expect(bytes == (try Data(contentsOf: fixture.snapshot)))
        #expect(try fixture.version(fixture.snapshot) == before)
    }

    @Test func verifyOnlyCannotCreateAJournal() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: RuntimeStorage(root: fixture.root))
        #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try anchor.withFile(.writeJournal, protection: .verifyOnly) { _ in Issue.record("Opened writable state") }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "journal.ndjson").path))
    }

    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var snapshot: URL { state.appending(path: "environments.json") }
        init() throws {
            var template = Array("/private/tmp/guesthouse-state-inspection-XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else { throw StorageFailure.inspectionFailed }
            base = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) } // Only this mkdtemp-owned fixture.
        func inspect() throws -> EnvironmentsSnapshot {
            try StateStore.inspectSnapshot(storage: { try RuntimeStorage.existing(root: self.root) })
        }
        func prepare(bytes: Data? = nil) throws {
            _ = try RuntimeStorage(root: root)
            try write(bytes ?? JSONEncoder().encode(EnvironmentsSnapshot.empty))
        }
        func write(_ bytes: Data) throws {
            try bytes.write(to: snapshot)
            try #require(chmod(snapshot.path, 0o600) == 0)
        }
        func version(_ url: URL) throws -> StateFileVersion {
            var value = stat()
            try #require(lstat(url.path, &value) == 0)
            return StateFileVersion(value)
        }
    }
}
