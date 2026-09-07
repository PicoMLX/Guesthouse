import Foundation
import Synchronization
import Testing
@testable import GuesthouseCore

@Suite struct StateStorePermissionDurabilityTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "StateStorePermissionDurability-\(UUID().uuidString)")

    enum Repair: Sendable { case mode, acl, both }

    @Test(arguments: [StateStore.snapshotFileName, StateStore.journalFileName], [Repair.mode, .acl, .both])
    func readOnlyFilePermissionsAreDurableBeforeAcceptance(name: String, repair: Repair) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (file, original) = try fixture(named: name)
        try prepareRepair(at: file, repair: repair)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var barriers = 0
        try StateStore.requirePrivateRegularFile(descriptor, name: name) { synchronized, synchronizedName in
            barriers += 1
            #expect(synchronized == descriptor)
            #expect(synchronizedName == name)
            #expect(try mode(synchronized) == 0o600)
            #expect(try !hasACL(synchronized))
            try StateStore.fullySynchronize(synchronized, name: synchronizedName)
        }
        #expect(barriers == 1)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test(arguments: [StateStore.snapshotFileName, StateStore.journalFileName])
    func failedPermissionBarrierRefusesReadAndRetrySynchronizes(name: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (file, original) = try fixture(named: name)
        try prepareRepair(at: file, repair: .both)
        let barriers = Mutex(0)
        let failure = StateStoreError.fileUnwritable(name: name)
        let store = try StateStore(rootURL: root, permissionBarrier: { descriptor, synchronizedName in
            #expect(synchronizedName == name)
            #expect(try mode(descriptor) == 0o600)
            #expect(try !hasACL(descriptor))
            let attempt = barriers.withLock { count in count += 1; return count }
            if attempt == 1 { throw failure }
            try StateStore.fullySynchronize(descriptor, name: synchronizedName)
        })
        await #expect(throws: failure) { try await read(name, from: store) }
        #expect(barriers.withLock { $0 } == 1)
        // The first attempt already repaired the visible metadata. Retrying must still
        // synchronize it: neither private mode nor an absent ACL proves durable privacy.
        try await read(name, from: store)
        #expect(barriers.withLock { $0 } == 2)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func failedDirectoryACLBarrierIsRetriedAfterTheACLIsGone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try grantACL(at: root)
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        // prepareDirectory applies the leaf's mode immediately before removeExtendedACL.
        try #require(fchmod(descriptor, 0o700) == 0)
        let failure = StateStoreError.fileUnwritable(name: root.lastPathComponent)
        var barriers = 0
        #expect(throws: failure) {
            try StateStore.removeExtendedACL(descriptor, name: root.lastPathComponent) { synchronized, _ in
                barriers += 1
                #expect(try mode(synchronized) == 0o700)
                #expect(try !hasACL(synchronized))
                throw failure
            }
        }
        try StateStore.removeExtendedACL(descriptor, name: root.lastPathComponent) { synchronized, name in
            barriers += 1
            #expect(try !hasACL(synchronized))
            try StateStore.fullySynchronize(synchronized, name: name)
        }
        #expect(barriers == 2)
    }

    private func fixture(named name: String) throws -> (URL, Data) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data: Data
        if name == StateStore.snapshotFileName {
            data = try JSONEncoder().encode(EnvironmentsSnapshot.empty)
        } else {
            let record = JournalRecord(
                id: OperationID(), environmentID: EnvironmentID(), operation: .startEnvironment,
                timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000), outcome: .started
            )
            var line = try JSONEncoder().encode(record)
            line.append(0x0A)
            data = line
        }
        let file = root.appending(path: name)
        try data.write(to: file)
        return (file, data)
    }

    private func prepareRepair(at file: URL, repair: Repair) throws {
        try #require(chmod(file.path, repair == .acl ? 0o600 : 0o666) == 0)
        if repair != .mode { try grantACL(at: file) }
    }

    private func read(_ name: String, from store: StateStore) async throws {
        if name == StateStore.snapshotFileName {
            #expect(try await store.loadSnapshot() == .empty)
        } else {
            #expect(try await store.replay().records.count == 1)
        }
    }
}

private func mode(_ descriptor: Int32) throws -> mode_t {
    var info = stat()
    try #require(fstat(descriptor, &info) == 0)
    return info.st_mode & 0o777
}

private func grantACL(at url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    var acl: acl_t? = acl_init(1)
    defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
    var entry: acl_entry_t?
    try #require(acl_create_entry(&acl, &entry) == 0)
    let created = try #require(entry)
    try #require(acl_set_tag_type(created, ACL_EXTENDED_ALLOW) == 0)
    var qualifier = try #require(UUID(uuidString: String(format: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA%08X", getuid()))).uuid
    try #require(withUnsafePointer(to: &qualifier) { acl_set_qualifier(created, UnsafeRawPointer($0)) } == 0)
    var permissions: acl_permset_t?
    try #require(acl_get_permset(created, &permissions) == 0)
    let permissionSet = try #require(permissions)
    let granted = try #require(acl)
    try #require(acl_add_perm(permissionSet, ACL_READ_DATA) == 0)
    try #require(acl_set_fd(descriptor, granted) == 0)
    try #require(try hasACL(descriptor))
}

private func hasACL(_ descriptor: Int32) throws -> Bool {
    errno = 0
    guard let acl = acl_get_fd(descriptor) else {
        try #require(errno == ENOENT)
        return false
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    try #require(acl_valid(acl) == 0)
    var entry: acl_entry_t?
    errno = 0
    let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
    try #require(result == 0 || (result == -1 && errno == EINVAL))
    return result == 0
}
