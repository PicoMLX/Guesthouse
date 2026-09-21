import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateSnapshotPublicationTests {
    @Test(arguments: [false, true])
    func separateAnchorsCannotPublishDuringEitherBarrier(afterRename: Bool) throws {
        let fixture = try Fixture()
        let other = try StateDirectoryAnchor(storage: RuntimeStorage(root: fixture.base.appending(path: "Guesthouse")))
        var visited = false
        let competing: StateFileProtection.Barrier = { _, _ in
            visited = true
            let names = try fixture.names()
            #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
                try StateSnapshotPublication.save(.empty, to: other,
                    createTemporary: { _, _, _, _ in Issue.record("Competing publication created a temporary"); return -1 })
            }
            #expect(try fixture.names() == names)
        }
        if afterRename {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, directoryBarrier: competing)
        } else {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor, fileBarrier: competing)
        }
        #expect(visited)
        // Ownership was released after success, not retained by an actor/anchor lifetime.
        try StateSnapshotPublication.save(.empty, to: other)
    }

    @Test func publicationOwnershipPrecedesPreflightAndReleasesOnFailure() throws {
        let fixture = try Fixture()
        let other = try StateDirectoryAnchor(storage: RuntimeStorage(root: fixture.base.appending(path: "Guesthouse")))
        let original = Data("corrupt evidence".utf8)
        try original.write(to: fixture.snapshot)
        try fixture.anchor.withPublicationOwnership { _ in
            #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
                try StateSnapshotPublication.save(.empty, to: other)
            }
            // A nested use of the same open description must not unlock its outer owner.
            #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
                try fixture.anchor.withPublicationOwnership { _ in }
            }
            try requireContended(fixture.state)
        }
        #expect(throws: StateStoreError.corruptSnapshot) {
            try StateSnapshotPublication.save(.empty, to: other)
        }
        try fixture.anchor.withPublicationOwnership { _ in }
        #expect(try Data(contentsOf: fixture.snapshot) == original)
    }

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

    @Test(arguments: [
        #""provisioning":[],"provisioning":[]"#,
        #""provisioning":[],"provisio\u006eing":[]"#,
        #""extra":{"items":[{"value":1,"value":2}]}"#
    ])
    func ambiguousSavedMembersPreserveOriginalBytes(members: String) throws {
        let fixture = try Fixture()
        let encoded = try JSONEncoder().encode(EnvironmentsSnapshot.empty)
        let original = Data(("{" + members + ",").utf8) + Data(encoded.dropFirst())
        try original.write(to: fixture.snapshot)
        #expect(throws: StateStoreError.corruptSnapshot) {
            try StateSnapshotPublication.save(.empty, to: fixture.anchor,
                createTemporary: { _, _, _, _ in Issue.record("Created over ambiguous state"); return -1 })
        }
        #expect(try Data(contentsOf: fixture.snapshot) == original)
        #expect(try fixture.names() == ["environments.json"])
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
