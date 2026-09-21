import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateSnapshotTemporariesTests {
    @Test(arguments: [
        (".environments.json.tmp-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", true),
        (".environments.json.tmp-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", false),
        (".environments.json.tmp-preserved", false),
        (".environments.json.tmp-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.extra", false),
        ("../.environments.json.tmp-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", false),
        (".environments.json.tmp-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE/child", false),
        (".environments.json.tmp-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE\0", false),
        ("environments.json", false), ("journal.ndjson", false),
    ])
    func onlyExactRuntimeTemporaryNamesQualify(name: String, expected: Bool) {
        #expect(StateSnapshotTemporaries.isManagedName(name) == expected)
    }

    @Test(arguments: [
        ("00000000-0000-0000-0000-000000000000", false),
        ("AAAAAAAA-BBBB-1CCC-8DDD-EEEEEEEEEEEE", false),
        ("AAAAAAAA-BBBB-3CCC-8DDD-EEEEEEEEEEEE", false),
        ("AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE", false),
        ("AAAAAAAA-BBBB-7CCC-8DDD-EEEEEEEEEEEE", false),
        ("AAAAAAAA-BBBB-4CCC-0DDD-EEEEEEEEEEEE", false),
        ("AAAAAAAA-BBBB-4CCC-4DDD-EEEEEEEEEEEE", false),
        ("AAAAAAAA-BBBB-4CCC-CDDD-EEEEEEEEEEEE", false),
        ("AAAAAAAA-BBBB-4CCC-FDDD-EEEEEEEEEEEE", false),
        ("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", true),
        ("AAAAAAAA-BBBB-4CCC-9DDD-EEEEEEEEEEEE", true),
        ("AAAAAAAA-BBBB-4CCC-ADDD-EEEEEEEEEEEE", true),
        ("AAAAAAAA-BBBB-4CCC-BDDD-EEEEEEEEEEEE", true),
    ])
    func onlyGeneratedUUIDShapesQualify(id: String, expected: Bool) {
        #expect(StateSnapshotTemporaries.isManagedName(StateSnapshotPublication.temporaryPrefix + id) == expected)
    }

    @Test(arguments: ["00000000-0000-0000-0000-000000000000", "AAAAAAAA-BBBB-4CCC-CDDD-EEEEEEEEEEEE"])
    func foreignUUIDArtifactsSurviveCollectionAndPublication(id: String) throws {
        let fixture = try Fixture()
        let candidate = fixture.state.appending(path: StateSnapshotPublication.temporaryPrefix + id)
        try fixture.evidence.write(to: candidate)
        try #require(chmod(candidate.path, 0o600) == 0)
        #expect(try fixture.collect() == 0)
        try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        #expect(try fixture.collect() == 0)
        #expect(try Data(contentsOf: candidate) == fixture.evidence)
    }

    @Test(arguments: [UInt32(UF_IMMUTABLE), UInt32(UF_APPEND)], [false, true])
    func flaggedArtifactsSurviveCollectionAndPublication(flag: UInt32, duringCheck: Bool) throws {
        let fixture = try Fixture(), candidate = try fixture.temporary()
        // Only this isolated fixture's flags are changed; production never repairs them.
        defer { _ = chflags(candidate.path, 0) }
        if !duringCheck { try #require(chflags(candidate.path, flag) == 0) }
        #expect(try fixture.collect { descriptor, _ in
            if duringCheck { try #require(fchflags(descriptor, flag) == 0) }
        } == 0)
        #expect(try fixture.collect() == 0)
        try StateSnapshotPublication.save(.empty, to: fixture.anchor)
        var info = stat()
        try #require(lstat(candidate.path, &info) == 0)
        #expect(info.st_flags == flag)
        #expect(try Data(contentsOf: candidate) == fixture.evidence)
    }

    @Test func removesOnlyPrivateStaleFilesAndCanEnumerateAgain() throws {
        let fixture = try Fixture()
        let first = try fixture.temporary(), second = try fixture.temporary()
        let unknown = fixture.state.appending(path: ".environments.json.tmp-preserved")
        try fixture.evidence.write(to: unknown)
        #expect(try fixture.collect() == 2)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(try Data(contentsOf: unknown) == fixture.evidence)
        let third = try fixture.temporary()
        #expect(try fixture.collect() == 1)
        #expect(!FileManager.default.fileExists(atPath: third.path))
        #expect(try fixture.collect() == 0)
        try fixture.anchor.verifyCurrent() // Enumeration did not consume/close the anchor.
    }

    @Test func activeWriterIsSkippedWithoutWaiting() throws {
        let fixture = try Fixture(), live = try fixture.temporary()
        let descriptor = open(live.path, O_RDONLY | O_EXLOCK | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        #expect(try fixture.collect() == 0)
        #expect(try Data(contentsOf: live) == fixture.evidence)
    }

    @Test(arguments: [1, 64]) func packedDirectoryRecordsAndLongUnrelatedNamesAreHandled(count: Int) throws {
        let fixture = try Fixture()
        for _ in 0..<count { _ = try fixture.temporary() }
        let unrelated = fixture.state.appending(path: String(repeating: "x", count: 255))
        try fixture.evidence.write(to: unrelated)
        #expect(try fixture.collect() == count)
        #expect(try Data(contentsOf: unrelated) == fixture.evidence)
    }

    @Test(arguments: ["symlink", "directory", "fifo", "hardLink", "wideMode"])
    func suspiciousCandidatesArePreservedWithoutRepair(kind: String) throws {
        let fixture = try Fixture()
        let candidate = fixture.state.appending(path: ".environments.json.tmp-\(UUID().uuidString)")
        let target = fixture.state.appending(path: "outside")
        try fixture.evidence.write(to: target)
        switch kind {
        case "symlink": try #require(symlink(target.path, candidate.path) == 0)
        case "directory": try #require(mkdir(candidate.path, 0o700) == 0)
        case "fifo": try #require(mkfifo(candidate.path, 0o600) == 0)
        case "hardLink": try #require(link(target.path, candidate.path) == 0)
        default:
            try fixture.evidence.write(to: candidate)
            try #require(chmod(candidate.path, 0o666) == 0)
        }
        var before = stat(), after = stat()
        try #require(lstat(candidate.path, &before) == 0)
        #expect(try fixture.collect() == 0)
        try #require(lstat(candidate.path, &after) == 0)
        #expect(after.st_mode == before.st_mode && after.st_nlink == before.st_nlink)
        #expect(try Data(contentsOf: target) == fixture.evidence)
    }

    @Test func aclBearingCandidateIsPreservedWithoutClearingItsACL() throws {
        let fixture = try Fixture(), candidate = try fixture.temporary()
        let descriptor = open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var acl: acl_t? = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?, permissions: acl_permset_t?
        try #require(acl_create_entry(&acl, &entry) == 0)
        let created = try #require(entry)
        try #require(acl_set_tag_type(created, ACL_EXTENDED_ALLOW) == 0)
        var qualifier = try #require(UUID(uuidString: String(format: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA%08X", getuid()))).uuid
        try #require(withUnsafePointer(to: &qualifier) { acl_set_qualifier(created, UnsafeRawPointer($0)) } == 0)
        try #require(acl_get_permset(created, &permissions) == 0)
        let permissionSet = try #require(permissions), granted = try #require(acl)
        try #require(acl_add_perm(permissionSet, ACL_READ_DATA) == 0)
        try #require(acl_set_fd(descriptor, granted) == 0)
        #expect(try fixture.collect() == 0)
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
            try StateFileProtection.verify(descriptor, kind: .regularFile)
        }
        #expect(try Data(contentsOf: candidate) == fixture.evidence)
    }

    @Test func cleanupLockSpansFinalValidationAndIsReleasedAfterFailure() throws {
        enum Failure: Error { case interrupted }
        let fixture = try Fixture(), candidate = try fixture.temporary()
        let observer = open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(observer >= 0)
        defer { close(observer) }
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try fixture.collect { descriptor, name in
                #expect(name == candidate.lastPathComponent)
                #expect(fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
                #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0)
                #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
                let result = flock(observer, LOCK_EX | LOCK_NB), failure = errno
                try #require(result == -1 && failure == EWOULDBLOCK)
                throw Failure.interrupted
            }
        }
        #expect(flock(observer, LOCK_EX | LOCK_NB) == 0)
        #expect(try Data(contentsOf: candidate) == fixture.evidence)
    }

    @Test func changedFileContentsAreNotDeleted() throws {
        let fixture = try Fixture(), candidate = try fixture.temporary()
        let changed = Data("changed fixture".utf8)
        #expect(try fixture.collect { _, _ in try changed.write(to: candidate) } == 0)
        #expect(try Data(contentsOf: candidate) == changed)
    }

    @Test func protectionDriftIsNotRepairedToEnableRemoval() throws {
        let fixture = try Fixture(), candidate = try fixture.temporary()
        #expect(try fixture.collect { descriptor, _ in try #require(fchmod(descriptor, 0o666) == 0) } == 0)
        var info = stat()
        try #require(lstat(candidate.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o666)
        #expect(try Data(contentsOf: candidate) == fixture.evidence)
    }

    @Test func replacedCandidateAndDetachedOriginalAreBothPreserved() throws {
        let fixture = try Fixture(), candidate = try fixture.temporary()
        let detached = fixture.state.appending(path: "detached"), replacement = Data("replacement fixture".utf8)
        // Replacement modifies the anchored directory's version too, so the store refuses
        // before unlink, not merely because it later notices a different candidate inode.
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try fixture.collect { _, _ in
                try #require(rename(candidate.path, detached.path) == 0)
                try replacement.write(to: candidate)
            }
        }
        #expect(try Data(contentsOf: candidate) == replacement)
        #expect(try Data(contentsOf: detached) == fixture.evidence)
    }

    @Test func directoryReattachmentCannotAuthorizeCleanup() throws {
        let fixture = try Fixture(), candidate = try fixture.temporary()
        let detached = fixture.base.appending(path: "detached")
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try fixture.collect { _, _ in
                try #require(rename(fixture.state.path, detached.path) == 0)
                try #require(rename(detached.path, fixture.state.path) == 0)
            }
        }
        #expect(try Data(contentsOf: candidate) == fixture.evidence)
    }

    @Test func theCallerRechecksItsSnapshotPreconditionBeforeDeletion() throws {
        let fixture = try Fixture(), candidate = try fixture.temporary()
        let failure = StateStoreError.newerSchemaVersion(found: SchemaVersion(99)!, current: SchemaVersion(2)!)
        var changed = false
        #expect(throws: failure) {
            try fixture.anchor.withDescriptor { directory in
                try StateSnapshotTemporaries.collect(in: directory, validateStore: { version in
                    try fixture.anchor.verifyCurrent(version: version)
                    if changed { throw failure }
                }, beforeRemoval: { _, _ in changed = true })
            }
        }
        #expect(try Data(contentsOf: candidate) == fixture.evidence)
    }

    @Test(arguments: ["{\"schemaVersion\":99}", "{\"schemaVersion\":1}", "damaged fixture"])
    func rejectedSavedStatePreservesEligibleTemporaries(raw: String) throws {
        let fixture = try Fixture(), candidate = try fixture.temporary()
        let snapshot = fixture.state.appending(path: "environments.json"), bytes = Data(raw.utf8)
        try bytes.write(to: snapshot)
        #expect(throws: StateStoreError.self) { try StateSnapshotPublication.save(.empty, to: fixture.anchor) }
        #expect(try Data(contentsOf: candidate) == fixture.evidence)
        #expect(try Data(contentsOf: snapshot) == bytes)
    }

    private final class Fixture {
        let base: URL
        let anchor: StateDirectoryAnchor
        let evidence = Data("private stale fixture".utf8)
        var state: URL { base.appending(path: "Guesthouse/state") }

        init() throws {
            let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-snapshot-temporaries-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let anchor: StateDirectoryAnchor
            do { anchor = try StateDirectoryAnchor(storage: RuntimeStorage(root: base.appending(path: "Guesthouse"))) }
            catch { try? FileManager.default.removeItem(at: base); throw error }
            self.base = base
            self.anchor = anchor
        }

        func temporary() throws -> URL {
            let url = state.appending(path: ".environments.json.tmp-\(UUID().uuidString)")
            try evidence.write(to: url)
            try #require(chmod(url.path, 0o600) == 0)
            return url
        }

        func collect(beforeRemoval: (Int32, String) throws -> Void = { _, _ in }) throws -> Int {
            try anchor.withDescriptor { directory in
                try StateSnapshotTemporaries.collect(in: directory,
                    validateStore: { try self.anchor.verifyCurrent(version: $0) }, beforeRemoval: beforeRemoval)
            }
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
