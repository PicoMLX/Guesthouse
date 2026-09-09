import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateFileProtectionTests {
    typealias Kind = StateFileProtection.Kind
    let original = Data("retained test work".utf8)

    func withArtifact(_ kind: Kind = .regularFile, body: (Int32, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "guesthouse-state-protection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = kind == .directory ? root : root.appending(path: "saved.json")
        if kind == .regularFile { try original.write(to: url) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (kind == .directory ? O_DIRECTORY : 0))
        try #require(fd >= 0)
        defer { close(fd) }
        try body(fd, url)
    }

    func mode(_ fd: Int32) throws -> mode_t {
        var info = stat()
        try #require(fstat(fd, &info) == 0)
        return info.st_mode & 0o7777
    }

    @Test(arguments: [mode_t(0o644), 0o666, 0o1600, 0o2600, 0o4600, 0o7600])
    func filePreparationRemovesWideAndSpecialModeBits(initial: mode_t) throws {
        try withArtifact { fd, url in
            try #require(fchmod(fd, initial) == 0)
            try StateFileProtection.prepare(fd, kind: .regularFile, name: .snapshot)
            #expect(try mode(fd) == 0o600)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test(arguments: [mode_t(0o755), 0o777, 0o1700, 0o2700, 0o4700])
    func directoryPreparationUsesExactlyPrivateMode(initial: mode_t) throws {
        try withArtifact(.directory) { fd, _ in
            try #require(fchmod(fd, initial) == 0)
            try StateFileProtection.prepare(fd, kind: .directory, name: .stateDirectory)
            #expect(try mode(fd) == 0o700)
        }
    }

    @Test(arguments: [Kind.regularFile, .directory])
    func verificationRefusesButDoesNotRepairWideModes(kind: Kind) throws {
        try withArtifact(kind) { fd, _ in
            try #require(fchmod(fd, 0o777) == 0)
            #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
                try StateFileProtection.verify(fd, kind: kind)
            }
            #expect(try mode(fd) == 0o777)
        }
    }

    @Test func foreignOwnershipIsRefusedBeforeAnyRepair() {
        var info = stat()
        info.st_mode = S_IFREG | 0o600
        info.st_nlink = 1
        info.st_uid = getuid() ^ 1
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
            try StateFileProtection.validateStructure(info, kind: .regularFile)
        }
    }

    @Test(arguments: [(Kind.regularFile, Kind.directory, StateStoreError.ProtectionFailure.notDirectory),
                      (.directory, .regularFile, .notRegularFile)])
    func wrongKindsAreRefusedWithoutChangingMode(actual: Kind, requested: Kind,
                                                failure: StateStoreError.ProtectionFailure) throws {
        try withArtifact(actual) { fd, _ in
            try #require(fchmod(fd, 0o755) == 0)
            #expect(throws: StateStoreError.insecureDirectory(reason: failure)) {
                try StateFileProtection.prepare(fd, kind: requested, name: .snapshot)
            }
            #expect(try mode(fd) == 0o755)
        }
    }

    @Test func multipleLinksAreRefusedBeforeChangingSharedMetadata() throws {
        try withArtifact { fd, url in
            try #require(link(url.path, url.deletingLastPathComponent().appending(path: "alias").path) == 0)
            try #require(fchmod(fd, 0o666) == 0)
            #expect(throws: StateStoreError.insecureDirectory(reason: .multipleLinks)) {
                try StateFileProtection.prepare(fd, kind: .regularFile, name: .journal)
            }
            #expect(try mode(fd) == 0o666)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    // Retains the descriptor-level behavior of StateStorePermissionDurabilityTests.
    // The original actor/read-path tests still need migration with the complete store.
    @Test(arguments: [StateStoreError.File.snapshot, .journal], [(mode_t(0o666), false), (0o600, true), (0o666, true)])
    func readOnlyFilePermissionsAreDurableBeforeAcceptance(name: StateStoreError.File,
                                                          repair: (mode_t, Bool)) throws {
        try withArtifact { fd, url in
            try prepareRepair(fd, mode: repair.0, acl: repair.1)
            var barriers = 0
            try StateFileProtection.prepare(fd, kind: .regularFile, name: name) { synchronized, logicalName in
                barriers += 1
                #expect(synchronized == fd)
                #expect(logicalName == name)
                #expect(try mode(synchronized) == 0o600)
                #expect(try !hasACL(synchronized))
                try StateFileIO.fullySynchronize(synchronized, name: logicalName)
            }
            #expect(barriers == 1)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test(arguments: [StateStoreError.File.snapshot, .journal])
    func failedPermissionBarrierIsRetriedDespiteVisibleRepair(name: StateStoreError.File) throws {
        try withArtifact { fd, url in
            try prepareRepair(fd, mode: 0o666, acl: true)
            let failure = StateStoreError.fileUnwritable(name: name)
            var barriers = 0
            #expect(throws: failure) {
                try StateFileProtection.prepare(fd, kind: .regularFile, name: name) { synchronized, _ in
                    barriers += 1
                    #expect(try mode(synchronized) == 0o600)
                    #expect(try !hasACL(synchronized))
                    throw failure
                }
            }
            try StateFileProtection.prepare(fd, kind: .regularFile, name: name) { synchronized, logicalName in
                barriers += 1
                try StateFileIO.fullySynchronize(synchronized, name: logicalName)
            }
            #expect(barriers == 2)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func failedDirectoryACLBarrierIsRetriedAfterTheACLIsGone() throws {
        try withArtifact(.directory) { fd, _ in
            try grantACL(fd)
            let failure = StateStoreError.fileUnwritable(name: .stateDirectory)
            var barriers = 0
            #expect(throws: failure) {
                try StateFileProtection.prepare(fd, kind: .directory, name: .stateDirectory) { synchronized, _ in
                    barriers += 1
                    #expect(try mode(synchronized) == 0o700)
                    #expect(try !hasACL(synchronized))
                    throw failure
                }
            }
            try StateFileProtection.prepare(fd, kind: .directory, name: .stateDirectory) { synchronized, name in
                barriers += 1
                try StateFileIO.fullySynchronize(synchronized, name: name)
            }
            #expect(barriers == 2)
        }
    }

    @Test(arguments: [Kind.regularFile, .directory])
    func alreadyPrivateMetadataStillRequiresABarrier(kind: Kind) throws {
        try withArtifact(kind) { fd, _ in
            try StateFileProtection.prepare(fd, kind: kind, name: .snapshot)
            var barriers = 0
            try StateFileProtection.prepare(fd, kind: kind, name: .snapshot) { _, _ in barriers += 1 }
            #expect(barriers == 1)
        }
    }

    @Test(arguments: [Kind.regularFile, .directory])
    func postBarrierModeDriftIsNotAccepted(kind: Kind) throws {
        try withArtifact(kind) { fd, _ in
            #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
                try StateFileProtection.prepare(fd, kind: kind, name: .snapshot) { synchronized, _ in
                    try #require(fchmod(synchronized, 0o777) == 0)
                }
            }
        }
    }

    @Test(arguments: [Kind.regularFile, .directory])
    func postBarrierACLDriftIsNotAccepted(kind: Kind) throws {
        try withArtifact(kind) { fd, _ in
            #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
                try StateFileProtection.prepare(fd, kind: kind, name: .snapshot) { synchronized, _ in
                    try grantACL(synchronized)
                }
            }
        }
    }

    @Test func postBarrierLinkCountDriftIsNotAccepted() throws {
        try withArtifact { fd, url in
            #expect(throws: StateStoreError.insecureDirectory(reason: .multipleLinks)) {
                try StateFileProtection.prepare(fd, kind: .regularFile, name: .journal) { _, _ in
                    try #require(link(url.path, url.deletingLastPathComponent().appending(path: "alias").path) == 0)
                }
            }
        }
    }

    @Test(arguments: [ENOENT, EIO, EBADF, ENOTSUP])
    func failedMetadataLookupNeverMeansNoACL(failure: Int32) throws {
        try withArtifact { fd, _ in
            try #require(fchmod(fd, 0o666) == 0)
            var barriers = 0
            #expect(throws: StateStoreError.insecureDirectory(reason: .unreadable)) {
                try StateFileProtection.prepare(fd, kind: .regularFile, name: .journal,
                    synchronize: { _, _ in barriers += 1 },
                    readMetadata: { _, _, _ in errno = failure; return -1 })
            }
            #expect(barriers == 0)
            #expect(try mode(fd) == 0o666)
        }
    }

    @Test func successfulStatWithoutSecurityMetadataIsNotPrivate() throws {
        try withArtifact { fd, _ in
            #expect(throws: StateStoreError.insecureDirectory(reason: .aclUnreadable)) {
                try StateFileProtection.verify(fd, kind: .regularFile, readMetadata: { descriptor, info, _ in
                    fstat(descriptor, info)
                })
            }
        }
    }

    @Test func unrelatedBarrierExceptionsBecomeClosedFailures() throws {
        enum TestFailure: Error { case interrupted }
        try withArtifact { fd, _ in
            #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                try StateFileProtection.prepare(fd, kind: .regularFile, name: .journal) { _, _ in
                    throw TestFailure.interrupted
                }
            }
        }
    }

    private func prepareRepair(_ fd: Int32, mode: mode_t, acl: Bool) throws {
        try #require(fchmod(fd, mode) == 0)
        if acl { try grantACL(fd) }
    }

    private func grantACL(_ fd: Int32) throws {
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
        try #require(acl_set_fd(fd, granted) == 0)
        try #require(try hasACL(fd))
    }

    private func hasACL(_ fd: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd(fd) else { try #require(errno == ENOENT); return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_valid(acl) == 0)
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        try #require(result == 0 || (result == -1 && errno == EINVAL))
        return result == 0
    }
}
