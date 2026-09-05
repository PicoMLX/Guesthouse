import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct LumeOwnershipGuardTests {
    private func fixture(enrolled: Bool = true) throws -> (RuntimeStorage, URL, LumeOwnershipEnrollment) {
        let root = FileManager.default.temporaryDirectory.appending(path: "LumeGuard-\(UUID())")
        let storage = try RuntimeStorage(root: root)
        let identity = try storage.coordinationIdentity()
        let enrollment = LumeOwnershipEnrollment(format: 1, id: UUID(), rootDevice: Int64(identity.device),
                                                 rootInode: UInt64(identity.inode))
        let marker = root.appending(path: LumeOwnershipGuard.fileName)
        // Synthetic fixture only: production has no enrollment authority or create API.
        if enrolled { try write(JSONEncoder().encode(enrollment), to: marker) }
        return (storage, marker, enrollment)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func addACL(to url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let acl = try #require(acl_from_text("!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000:root:0:allow:read\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_fd(descriptor, acl) == 0)
    }

    @Test func opensAnExistingEnrollmentWithoutTreatingLockReleaseAsLeaseClearance() throws {
        let (storage, _, enrollment) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let guardFile = try LumeOwnershipGuard(storage: storage)
        #expect(guardFile.enrollment == enrollment)
        #expect(try guardFile.withLock { _, stored in stored } == enrollment)
        #expect(throws: LumeOwnershipStorageFailure.ioFailure) {
            try guardFile.withLock { _, _ in throw LumeOwnershipStorageFailure.ioFailure }
        }
        #expect(try guardFile.withLock { _, stored in stored } == enrollment)
    }

    @Test func absenceNeverCreatesEnrollment() throws {
        let (storage, marker, _) = try fixture(enrolled: false)
        defer { try? FileManager.default.removeItem(at: storage.root) }
        #expect(throws: LumeOwnershipStorageFailure.notEnrolled) { try LumeOwnershipGuard(storage: storage) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: ["malformed", "future", "other-root", "oversized"])
    func rejectsInvalidEnrollment(kind: String) throws {
        let (storage, marker, enrollment) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let bytes: Data
        switch kind {
        case "future":
            bytes = try JSONEncoder().encode(LumeOwnershipEnrollment(format: 2, id: enrollment.id,
                rootDevice: enrollment.rootDevice, rootInode: enrollment.rootInode))
        case "other-root":
            bytes = try JSONEncoder().encode(LumeOwnershipEnrollment(format: 1, id: enrollment.id,
                rootDevice: enrollment.rootDevice, rootInode: enrollment.rootInode + 1))
        case "oversized": bytes = Data(repeating: 32, count: 4_097)
        default: bytes = Data("not JSON".utf8)
        }
        try write(bytes, to: marker)
        #expect(throws: LumeOwnershipStorageFailure.invalidEnrollment) { try LumeOwnershipGuard(storage: storage) }
        #expect(try Data(contentsOf: marker) == bytes)
    }

    @Test(arguments: ["link", "directory", "fifo", "hard-link", "mode", "acl"])
    func refusesUnsafeMarkerWithoutRepair(kind: String) throws {
        let (storage, marker, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let preserved = storage.root.appending(path: "preserved")
        switch kind {
        case "link", "directory", "fifo":
            try FileManager.default.moveItem(at: marker, to: preserved)
            if kind == "link" { try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: preserved) }
            if kind == "directory" { try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false) }
            if kind == "fifo" { try #require(mkfifo(marker.path, 0o600) == 0) }
        case "hard-link": try #require(link(marker.path, preserved.path) == 0)
        case "mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
        default: try addACL(to: marker)
        }
        #expect(throws: LumeOwnershipStorageFailure.self) { try LumeOwnershipGuard(storage: storage) }
        if kind == "mode" {
            #expect(try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int == 0o644)
        }
        if kind == "acl" { #expect(try RuntimeStorage.hasAccessControlEntries(marker)) }
    }

    @Test func aSecondOpenerAndRecursiveLockCannotEnterAnActiveTransaction() throws {
        let (storage, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let first = try LumeOwnershipGuard(storage: storage)
        let second = try LumeOwnershipGuard(storage: storage)
        try first.withLock { _, _ in
            #expect(throws: LumeOwnershipStorageFailure.guardBusy) { try second.withLock { _, _ in } }
            #expect(throws: LumeOwnershipStorageFailure.guardBusy) { try first.withLock { _, _ in } }
            #expect(throws: LumeOwnershipStorageFailure.guardBusy) { try LumeOwnershipGuard(storage: storage) }
        }
        try second.withLock { _, _ in }
    }

    @Test func copiedReplacementCannotReuseAnOpenGuard() throws {
        let (storage, marker, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let guardFile = try LumeOwnershipGuard(storage: storage)
        let originalIdentity = guardFile.identity
        let bytes = try Data(contentsOf: marker)
        try FileManager.default.moveItem(at: marker, to: storage.root.appending(path: "preserved"))
        try write(bytes, to: marker)
        #expect(throws: LumeOwnershipStorageFailure.guardChanged) { try guardFile.withLock { _, _ in } }
        let copied = try LumeOwnershipGuard(storage: storage)
        #expect(copied.identity != originalIdentity, "the ledger must also bind this physical guard identity")
    }

    @Test func replacementDuringTransactionCannotReportSuccess() throws {
        let (storage, marker, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let guardFile = try LumeOwnershipGuard(storage: storage)
        #expect(throws: LumeOwnershipStorageFailure.guardChanged) {
            try guardFile.withLock { _, _ in
                try FileManager.default.moveItem(at: marker, to: storage.root.appending(path: "preserved"))
            }
        }
    }

    @Test func barrierFailureDoesNotCreateOrRewriteTheMarker() throws {
        let (storage, marker, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let bytes = try Data(contentsOf: marker)
        #expect(throws: LumeOwnershipStorageFailure.ioFailure) {
            try LumeOwnershipGuard(storage: storage) { _ in throw LumeOwnershipStorageFailure.ioFailure }
        }
        #expect(try Data(contentsOf: marker) == bytes)
        _ = try LumeOwnershipGuard(storage: storage)
    }

    @Test func markerReplacementAtDurabilityBarrierIsRejected() throws {
        let (storage, marker, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let bytes = try Data(contentsOf: marker)
        var replaced = false
        #expect(throws: LumeOwnershipStorageFailure.guardChanged) {
            try LumeOwnershipGuard(storage: storage) { descriptor in
                try LumeOwnershipIO.synchronize(descriptor)
                if !replaced {
                    replaced = true
                    try FileManager.default.moveItem(at: marker, to: storage.root.appending(path: "preserved"))
                    try write(bytes, to: marker)
                }
            }
        }
    }

    @Test func failuresAlwaysOfferInspectionWithoutAutomaticRepair() {
        #expect(LumeOwnershipStorageFailure.guardChanged.recoveryActions == [.inspectState, .cancel])
        #expect(LumeOwnershipStorageFailure.guardChanged.errorDescription?.contains("Keep its storage unchanged") == true)
    }

    @Test(arguments: [false, true])
    func rootProtectionDriftRequiresInspectionWithoutRepair(acl: Bool) throws {
        let (storage, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let guardFile = try LumeOwnershipGuard(storage: storage)
        #expect(throws: LumeOwnershipStorageFailure.insecureFile) {
            try guardFile.withLock { _, _ in
                if acl { try addACL(to: storage.root) }
                else { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.root.path) }
            }
        }
        let failure = #expect(throws: LumeOwnershipStorageFailure.self) { try LumeOwnershipGuard(storage: storage) }
        #expect(failure?.recoveryActions == [.inspectState, .cancel])
        #expect(throws: LumeOwnershipStorageFailure.insecureFile) { try guardFile.withLock { _, _ in } }
        if acl { #expect(try RuntimeStorage.hasAccessControlEntries(storage.root)) }
        else { #expect(try FileManager.default.attributesOfItem(atPath: storage.root.path)[.posixPermissions] as? Int == 0o755) }
    }

    @Test func sameInodeMarkerDriftAtBarrierIsRejected() throws {
        let (storage, marker, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        var changed = false
        #expect(throws: LumeOwnershipStorageFailure.insecureFile) {
            try LumeOwnershipGuard(storage: storage) { descriptor in
                try LumeOwnershipIO.synchronize(descriptor)
                if !changed {
                    changed = true
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
                }
            }
        }
    }

    @Test func sameInodeContentChangesCannotBecomeANewBaseline() throws {
        let (storage, marker, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let guardFile = try LumeOwnershipGuard(storage: storage)
        let descriptor = open(marker.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var whitespace: UInt8 = 32
        try #require(Darwin.write(descriptor, &whitespace, 1) == 1)
        #expect(throws: LumeOwnershipStorageFailure.guardChanged) { try guardFile.withLock { _, _ in } }
    }

    @Test func everyOpenRepeatsAncestryBarriersAndLaterFailureRefusesOpening() throws {
        let (storage, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        var first: [LumeOwnershipFileVersion] = []
        _ = try LumeOwnershipGuard(storage: storage) { fd in
            first.append(try LumeOwnershipIO.version(fd))
            try LumeOwnershipIO.synchronize(fd)
        }
        var second: [LumeOwnershipFileVersion] = []
        _ = try LumeOwnershipGuard(storage: storage) { fd in
            second.append(try LumeOwnershipIO.version(fd))
            try LumeOwnershipIO.synchronize(fd)
        }
        #expect(first.map(\.identity) == second.map(\.identity))
        #expect(first.count > 3, "marker, root and its ancestry are independently synchronized")
        var barriers = 0
        #expect(throws: LumeOwnershipStorageFailure.ioFailure) {
            try LumeOwnershipGuard(storage: storage) { fd in
                barriers += 1
                if barriers == 3 { throw LumeOwnershipStorageFailure.ioFailure }
                try LumeOwnershipIO.synchronize(fd)
            }
        }
        #expect(barriers == 3)
        let guardFile = try LumeOwnershipGuard(storage: storage)
        #expect(throws: LumeOwnershipStorageFailure.guardBusy) { try guardFile.validate() }
    }
}
