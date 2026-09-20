import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateSnapshotPublicationTests {
    @Test func firstSaveAndReplacementUseNewPrivateInodes() throws {
        let fixture = try Fixture()
        try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        let first = try fixture.identity(fixture.snapshot)
        try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        #expect(try fixture.identity(fixture.snapshot) != first)
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: Data(contentsOf: fixture.snapshot)) == .empty)
        #expect(try fixture.names() == ["environments.json"])
        _ = try fixture.anchor.withFile(.readSnapshot, body: { try StateFileProtection.verify($0, kind: .regularFile) })
    }

    @Test(arguments: [SchemaVersion.unversioned, SchemaVersion(1)!, SchemaVersion(99)!])
    func rejectedValuePreservesSavedBytesAndAllTemporaries(version: SchemaVersion) throws {
        let fixture = try Fixture()
        let original = Data("original fixture".utf8), stale = fixture.state.appending(path: ".environments.json.tmp-preserved")
        try original.write(to: fixture.snapshot)
        try original.write(to: stale)
        #expect(throws: StateStoreError.unsupportedSnapshotVersion(found: version, current: SchemaVersion(2)!)) {
            try StateSnapshotPublication.save(EnvironmentsSnapshot(schemaVersion: version), to: fixture.anchor,
                createTemporary: { _, _, _, _ in Issue.record("Created a rejected value"); return -1 })
        }
        #expect(try Data(contentsOf: fixture.snapshot) == original)
        #expect(try Data(contentsOf: stale) == original)
        #expect(try fixture.names().count == 2)
    }

    @Test func nonfiniteDateFailsBeforeAnyFilesystemWork() throws {
        let fixture = try Fixture()
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: Date(timeIntervalSinceReferenceDate: .infinity))
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let value = EnvironmentsSnapshot(environments: [environment], slots: slots)
        #expect(throws: StateStoreError.unencodable(name: .snapshot)) {
            try StateSnapshotPublication.save(value, to: fixture.anchor,
                createTemporary: { _, _, _, _ in Issue.record("Created an unencodable value"); return -1 })
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test func oversizedEncodingCannotPublishAnUnreadableSnapshot() throws {
        let fixture = try Fixture()
        let environment = DevelopmentEnvironment(name: String(repeating: "x", count: 4 * 1024 * 1024))
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let value = EnvironmentsSnapshot(environments: [environment], slots: slots)
        #expect(throws: StateStoreError.unencodable(name: .snapshot)) {
            try StateSnapshotPublication.save(value, to: fixture.anchor)
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test func inconsistentValueCannotCreateState() throws {
        let fixture = try Fixture()
        let value = EnvironmentsSnapshot(environments: [DevelopmentEnvironment(name: "Dev")])
        #expect(throws: StateStoreError.inconsistentSnapshot(reason: .slotsDisagree)) {
            try StateSnapshotPublication.save(value, to: fixture.anchor)
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test func migratorCannotSelectAnUnsupportedWriterVersion() throws {
        let fixture = try Fixture()
        let future = SnapshotMigrator(current: SchemaVersion(99)!, migrations: [])
        #expect(throws: StateStoreError.unsupportedSnapshotVersion(found: SchemaVersion(2)!, current: SchemaVersion(99)!)) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, migrator: future)
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test(arguments: [
        ("{\"schemaVersion\":99,\"futureField\":true}", StateStoreError.newerSchemaVersion(found: SchemaVersion(99)!, current: SchemaVersion(2)!)),
        ("{\"schemaVersion\":1}", .migrationMissing(from: SchemaVersion(1)!)),
        ("{}", .migrationMissing(from: .unversioned)),
        ("{\"schemaVersion\":2}", .corruptSnapshot),
        ("damaged fixture", .corruptSnapshot),
    ])
    func unsupportedOrDamagedSavedStateCannotBeOverwritten(raw: String, failure: StateStoreError) throws {
        let fixture = try Fixture()
        let data = Data(raw.utf8)
        try data.write(to: fixture.snapshot)
        #expect(throws: failure) { try StateSnapshotPublication.save(.empty, to: fixture.anchor) }
        #expect(try Data(contentsOf: fixture.snapshot) == data)
        #expect(try fixture.names() == ["environments.json"])
    }

    @Test func secondSnapshotNameIsRefusedBeforeReplacement() throws {
        let fixture = try Fixture()
        try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        let bytes = try Data(contentsOf: fixture.snapshot)
        try #require(link(fixture.snapshot.path, fixture.state.appending(path: "alias").path) == 0)
        #expect(throws: StateStoreError.insecureDirectory(reason: .multipleLinks)) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        }
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
        #expect(try fixture.names().count == 2)
    }

    @Test func oneAtomicLockSpansPrivatePreparationWriteAndPublication() throws {
        let fixture = try Fixture()
        var temporary: URL?, barriers: [StateStoreError.File] = []
        try StateSnapshotPublication.save(.empty, to: fixture.anchor, permissionBarrier: { fd, label in
            barriers.append(label)
            try requireContended(try #require(temporary))
            #expect(try StateFileProtection.verify(fd, kind: .regularFile).st_mode & 0o7777 == 0o600)
        }, fileBarrier: { fd, label in
            barriers.append(label)
            try requireContended(try #require(temporary))
            try StateFileIO.fullySynchronize(fd, name: label)
        }, directoryBarrier: { fd, label in
            barriers.append(label)
            try requireContended(fixture.snapshot)
            try StateFileIO.fullySynchronize(fd, name: label)
        }, createTemporary: { directory, name, flags, mode in
            #expect(flags == O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK)
            #expect(mode == 0o600)
            #expect(name.hasPrefix(".environments.json.tmp-"))
            #expect(UUID(uuidString: String(name.dropFirst(23))) != nil)
            temporary = fixture.state.appending(path: name)
            let fd = openat(directory, name, flags, mode)
            #expect(fd >= 0)
            // Simulate a restrictive umask without changing process-global state.
            #expect(fchmod(fd, 0o400) == 0)
            return fd
        })
        #expect(barriers == [.snapshot, .snapshot, .stateDirectory])
        let reader = open(fixture.snapshot.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(reader >= 0)
        defer { close(reader) }
        #expect(flock(reader, LOCK_EX | LOCK_NB) == 0)
    }

    @Test(arguments: [ENOTSUP, EOPNOTSUPP, EINTR, EEXIST])
    func failedAtomicCreationIsNotRetriedOrDowngraded(failure: Int32) throws {
        let fixture = try Fixture()
        var attempts = 0
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, createTemporary: { _, _, _, _ in
                attempts += 1
                errno = failure
                return -1
            })
        }
        #expect(attempts == 1)
        #expect(try fixture.names().isEmpty)
    }

    @Test func failedExclusiveOpenDoesNotDeleteTheCollidingEntry() throws {
        let fixture = try Fixture()
        let bytes = Data("existing temporary".utf8)
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, createTemporary: { directory, name, flags, mode in
                do { try bytes.write(to: fixture.state.appending(path: name)) }
                catch { Issue.record("Could not create collision fixture") }
                return openat(directory, name, flags, mode)
            })
        }
        let name = try #require(try fixture.names().first)
        #expect(try Data(contentsOf: fixture.state.appending(path: name)) == bytes)
    }

    @Test func failedFileBarrierPreservesTheOriginalAndUnpublishedTemporary() throws {
        enum Failure: Error { case interrupted }
        let fixture = try Fixture()
        try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        let original = try fixture.identity(fixture.snapshot)
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, fileBarrier: { _, _ in throw Failure.interrupted })
        }
        #expect(try fixture.identity(fixture.snapshot) == original)
        #expect(try fixture.names().count == 2)
        let temporary = try #require(try fixture.names().first { $0 != "environments.json" })
        let bytes = try Data(contentsOf: fixture.state.appending(path: temporary))
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: bytes) == .empty)
    }

    @Test func failedDirectoryBarrierPreservesPublishedEvidence() throws {
        let fixture = try Fixture()
        let failure = StateStoreError.fileUnwritable(name: .stateDirectory)
        #expect(throws: failure) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, directoryBarrier: { _, _ in throw failure })
        }
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: Data(contentsOf: fixture.snapshot)) == .empty)
        #expect(try fixture.names() == ["environments.json"])
    }

    @Test func failedPermissionBarrierDoesNotPublishOrDeleteTheTemporary() throws {
        let fixture = try Fixture()
        let failure = StateStoreError.fileUnwritable(name: .snapshot)
        #expect(throws: failure) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, permissionBarrier: { _, _ in throw failure })
        }
        let name = try #require(try fixture.names().first)
        #expect(name.hasPrefix(".environments.json.tmp-"))
        #expect(try Data(contentsOf: fixture.state.appending(path: name)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
    }

    @Test func rewritingTheTemporaryDuringItsFileBarrierIsRefused() throws {
        let fixture = try Fixture(), changed = Data("changed temporary".utf8)
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, fileBarrier: { fd, _ in
                try #require(ftruncate(fd, 0) == 0)
                try #require(lseek(fd, 0, SEEK_SET) == 0)
                try StateFileIO.writeAll(fd, changed, name: .snapshot)
            })
        }
        let name = try #require(try fixture.names().first)
        #expect(try Data(contentsOf: fixture.state.appending(path: name)) == changed)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
    }

    @Test func aChangedExistingSnapshotIsNotOverwrittenAfterPreflight() throws {
        let fixture = try Fixture()
        try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        let future = Data("{\"schemaVersion\":99,\"preserve\":true}".utf8)
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, fileBarrier: { _, _ in
                try future.write(to: fixture.snapshot)
            })
        }
        #expect(try Data(contentsOf: fixture.snapshot) == future)
    }

    @Test func aTemporaryReplacedDuringTheFileBarrierIsNeverPublished() throws {
        let fixture = try Fixture()
        let replacement = Data("replacement temporary".utf8)
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, fileBarrier: { _, _ in
                let name = try #require(try fixture.names().first)
                let temporary = fixture.state.appending(path: name)
                try #require(rename(temporary.path, fixture.state.appending(path: "detached").path) == 0)
                try replacement.write(to: temporary)
            })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        let retained = try Data(contentsOf: fixture.state.appending(path: "detached"))
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: retained) == .empty)
    }

    @Test(arguments: [(false, StateStoreError.fileUnwritable(name: .snapshot)), (true, .insecureDirectory(reason: .changed))])
    func replacementDuringPublicationIsRefused(directory: Bool, failure: StateStoreError) throws {
        let fixture = try Fixture(), replacement = Data("replacement fixture".utf8)
        let target = directory ? fixture.state : fixture.snapshot, detached = fixture.base.appending(path: "detached")
        #expect(throws: failure) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, directoryBarrier: { fd, label in
                try StateFileIO.fullySynchronize(fd, name: label)
                try #require(rename(target.path, detached.path) == 0)
                if directory { try #require(mkdir(fixture.state.path, 0o700) == 0) }
                try replacement.write(to: fixture.snapshot)
            })
        }
        #expect(try Data(contentsOf: fixture.snapshot) == replacement)
        let retained = directory ? detached.appending(path: "environments.json") : detached
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: Data(contentsOf: retained)) == .empty)
    }

    @Test(arguments: [(false, StateStoreError.fileUnwritable(name: .snapshot)), (true, .insecureDirectory(reason: .changed))])
    func sameInodeReattachmentDuringPublicationIsRefused(directory: Bool, failure: StateStoreError) throws {
        let fixture = try Fixture()
        let target = directory ? fixture.state : fixture.snapshot, detached = fixture.base.appending(path: "detached")
        #expect(throws: failure) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, directoryBarrier: { fd, label in
                try StateFileIO.fullySynchronize(fd, name: label)
                let identity = try fixture.identity(target)
                try #require(rename(target.path, detached.path) == 0)
                try #require(rename(detached.path, target.path) == 0)
                try #require(try fixture.identity(target) == identity)
            })
        }
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: Data(contentsOf: fixture.snapshot)) == .empty)
    }

    @Test func thisPublicationDoesNotCollectOtherWritersOrStaleEvidence() throws {
        let fixture = try Fixture(), evidence = Data("retained temporary".utf8)
        let live = fixture.state.appending(path: ".environments.json.tmp-\(UUID().uuidString)")
        let stale = fixture.state.appending(path: ".environments.json.tmp-\(UUID().uuidString)")
        try evidence.write(to: live)
        try evidence.write(to: stale)
        let held = open(live.path, O_RDONLY | O_EXLOCK | O_NOFOLLOW | O_CLOEXEC)
        try #require(held >= 0)
        defer { close(held) }
        try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        #expect(try Data(contentsOf: live) == evidence)
        #expect(try Data(contentsOf: stale) == evidence)
    }

    private func requireContended(_ path: URL) throws {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let result = flock(descriptor, LOCK_EX | LOCK_NB), failure = errno
        try #require(result == -1 && failure == EWOULDBLOCK)
    }

    private final class Fixture {
        let base: URL
        let anchor: StateDirectoryAnchor
        var state: URL { base.appending(path: "Guesthouse/state") }
        var snapshot: URL { state.appending(path: "environments.json") }

        init() throws {
            let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-snapshot-publication-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let anchor: StateDirectoryAnchor
            do { anchor = try StateDirectoryAnchor(storage: RuntimeStorage(root: base.appending(path: "Guesthouse"))) }
            catch { try? FileManager.default.removeItem(at: base); throw error }
            self.base = base
            self.anchor = anchor
        }

        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: state.path) }
        func identity(_ path: URL) throws -> StateFileIdentity {
            var info = stat()
            try #require(lstat(path.path, &info) == 0)
            return StateFileIdentity(info)
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
