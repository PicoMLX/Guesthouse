import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateStoreInspectionTests {
    @Test(arguments: [StateFileAccess.inspectSnapshot, .inspectJournal], [false, true])
    func inspectionPreservesProtectionAndBytes(access: StateFileAccess, privateMode: Bool) throws {
        let fixture = try Fixture()
        let file = fixture.root.appending(path: "state/" + access.name)
        let original = Data("saved evidence".utf8)
        try original.write(to: file)
        try #require(chmod(file.path, privateMode ? 0o600 : 0o644) == 0)
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        var before = stat(), after = stat()
        try #require(lstat(file.path, &before) == 0)
        let read = {
            try anchor.withFile(access, permissionBarrier: { _, _ in Issue.record("Inspection repaired permissions") },
                body: { fd in
                    #expect(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY)
                    return try StateFileIO.readAll(fd, from: 0, name: access.label)
                })
        }
        if privateMode { #expect(try read() == original) }
        else { #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) { try read() } }
        try #require(lstat(file.path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_mode == after.st_mode)
        #expect(before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test(arguments: [StateFileAccess.inspectSnapshot, .inspectJournal])
    func inspectionPreservesUnexpectedACL(access: StateFileAccess) throws {
        let fixture = try Fixture()
        let file = fixture.root.appending(path: "state/" + access.name)
        let original = Data("saved evidence".utf8)
        try original.write(to: file)
        try #require(chmod(file.path, 0o600) == 0)
        var acl = acl_init(1), entry: acl_entry_t?
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        try #require(acl_create_entry(&acl, &entry) == 0)
        let created = try #require(entry)
        try #require(acl_set_tag_type(created, ACL_EXTENDED_ALLOW) == 0)
        var qualifier = try #require(UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")).uuid
        try #require(withUnsafePointer(to: &qualifier) { acl_set_qualifier(created, $0) } == 0)
        var permissions: acl_permset_t?
        try #require(acl_get_permset(created, &permissions) == 0)
        let permissionSet = try #require(permissions), granted = try #require(acl)
        try #require(acl_add_perm(permissionSet, ACL_READ_DATA) == 0)
        try #require(acl_set_link_np(file.path, ACL_TYPE_EXTENDED, granted) == 0)
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
            try anchor.withFile(access, body: { _ in Issue.record("Accepted an ACL"); return true })
        }
        let retained = try #require(acl_get_link_np(file.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(retained)) }
        var retainedEntry: acl_entry_t?
        #expect(acl_get_entry(retained, ACL_FIRST_ENTRY.rawValue, &retainedEntry) == 0)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test(arguments: [StateFileAccess.inspectSnapshot, .inspectJournal])
    func missingInspectionNeverCreatesAFile(access: StateFileAccess) throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        #expect(try anchor.withFile(access, body: { _ in Issue.record("Missing entry opened"); return true }) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "state").path).isEmpty)
    }

    @Test(arguments: [false, true], [0o644, 0o000])
    func startupRefusesProtectionDriftWithoutChangingOrLosingSavedWork(journal: Bool, mode: Int) async throws {
        let fixture = try Fixture()
        let owner = try await fixture.open()
        _ = try await owner.loadSnapshot()
        try await owner.saveSnapshot(.empty)
        _ = try await owner.replay()
        let operation = try await owner.begin(.startEnvironment, for: EnvironmentID())
        await owner.close()
        let file = fixture.root.appending(path: journal ? "state/journal.ndjson" : "state/environments.json")
        let original = try Data(contentsOf: file)
        try #require(chmod(file.path, mode_t(mode)) == 0)
        let loader = RuntimeStateLoader(open: { () async throws(StateStoreError) -> StateStore in try await fixture.open() })
        await loader.load()
        #expect(loader.status == .repairRequired && loader.loadedState == nil)
        var info = stat()
        try #require(lstat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == mode_t(mode))
        // Explicit fixture-only repair permits a later read; it does not settle the operation.
        try #require(chmod(file.path, 0o600) == 0)
        #expect(try Data(contentsOf: file) == original)
        let reopened = try await fixture.open()
        #expect(try await reopened.loadSnapshot() == .empty)
        #expect(try await reopened.replay().inFlight[operation] != nil)
        await reopened.close()
    }

    private final class Fixture: Sendable {
        let root: URL
        let storage: RuntimeStorage
        init() throws {
            let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-inspection-\(UUID())")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            root = base.appending(path: "Guesthouse")
            storage = try RuntimeStorage(root: root)
        }
        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        func open() async throws(StateStoreError) -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(existingRoot: self.root) })
        }
    }
}
