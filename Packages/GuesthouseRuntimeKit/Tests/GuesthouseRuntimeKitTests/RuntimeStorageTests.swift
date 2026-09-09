import Darwin
import Foundation
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct RuntimeStorageTests {
    @Test(arguments: [
        (RuntimeStorage.Area.runtime, "runtime", false), (.vms, "vms", false), (.state, "state", false),
        (.staging, "staging", true), (.downloads, "downloads", true), (.diagnostics, "diagnostics", false),
        (.sshMaintenance, "ssh/maintenance", false),
    ])
    func preparesTheFixedPrivateLayout(_ area: RuntimeStorage.Area, _ path: String, _ excluded: Bool) throws {
        let fixture = try Fixture()
        let storage = try RuntimeStorage(root: fixture.storage)
        let result = try storage.location(for: area)
        #expect(result == fixture.storage.appending(path: path))
        try StorageProtection.verify(result)
        try StorageProtection.verify(fixture.storage)
        try StorageProtection.verify(fixture.storage.appending(path: "ssh"))
        #expect(try backupExcluded(result) == excluded)
        #expect(try !backupExcluded(fixture.storage))
    }

    @Test func missingIntermediatesAreCreatedPrivatelyAfterPreflight() throws {
        let fixture = try Fixture()
        let root = fixture.base.appending(path: "Library/Application Support/Guesthouse")
        _ = try RuntimeStorage(root: root)
        for suffix in ["Library", "Library/Application Support", "Library/Application Support/Guesthouse"] {
            try StorageProtection.verify(fixture.base.appending(path: suffix))
        }
    }

    @Test(arguments: [false, true], ["Guesthouse", "Guesthouse/vms", "Guesthouse/ssh"])
    func linksAreRefusedBeforeAnyPreparation(_ dangling: Bool, _ suffix: String) throws {
        let fixture = try Fixture()
        let link = fixture.base.appending(path: suffix), target = fixture.base.appending(path: "outside")
        if !dangling { try fixture.directory(target) }
        try fixture.directory(link.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: StorageFailure.unsafeStructure) { _ = try RuntimeStorage(root: fixture.storage) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.appending(path: "runtime").path))
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "maintenance").path))
    }

    @Test func lateLayoutBlockerIsRefusedBeforeRepairingRootOrCreatingSiblings() throws {
        let fixture = try Fixture()
        try fixture.directory(fixture.storage, mode: 0o755)
        let blocker = fixture.storage.appending(path: "diagnostics")
        try Data("keep me".utf8).write(to: blocker)
        #expect(throws: StorageFailure.unsafeStructure) { _ = try RuntimeStorage(root: fixture.storage) }
        #expect(try StorageProtection.structure(fixture.storage).st_mode & 0o7777 == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path) == ["diagnostics"])
        #expect(try Data(contentsOf: blocker) == Data("keep me".utf8))
    }

    @Test(arguments: [false, true]) func unsafeAncestorPreventsCreationAndRepair(_ exists: Bool) async throws {
        let fixture = try Fixture()
        let root = fixture.base.appending(path: "parent/Guesthouse")
        try fixture.directory(root.deletingLastPathComponent())
        if exists {
            try fixture.directory(root, mode: 0o755)
            try await fixture.addACL("everyone allow read,list", at: root)
            try Data("keep me".utf8).write(to: root.appending(path: "unpublished"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.deletingLastPathComponent().path)
        #expect(throws: StorageFailure.unsafeStructure) { _ = try RuntimeStorage(root: root) }
        #expect(FileManager.default.fileExists(atPath: root.path) == exists)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "runtime").path))
        if exists {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.deletingLastPathComponent().path)
            // Restoring the ancestor does not erase the refused root ACL or unpublished file.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            #expect(throws: StorageFailure.protectionDrift) { try StorageProtection.verify(root) }
            #expect(try Data(contentsOf: root.appending(path: "unpublished")) == Data("keep me".utf8))
        }
    }

    @Test func validAncestorAliasIsPreserved() throws {
        let fixture = try Fixture()
        let target = fixture.base.appending(path: "target"), alias = fixture.base.appending(path: "alias")
        try fixture.directory(target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let storage = try RuntimeStorage(root: alias.appending(path: "Guesthouse"))
        try StorageProtection.verify(storage.location(for: .vms))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == target.path)
    }

    @Test(arguments: ["", "runtime", "vms", "state", "staging", "downloads", "diagnostics", "ssh", "ssh/maintenance"],
          [false, true])
    func everyManagedComponentRejectsModeOrACLDriftWithoutRepair(_ suffix: String, _ acl: Bool) async throws {
        let fixture = try Fixture()
        let storage = try RuntimeStorage(root: fixture.storage)
        let target = suffix.isEmpty ? fixture.storage : fixture.storage.appending(path: suffix)
        let area: RuntimeStorage.Area = suffix == "ssh" || suffix == "ssh/maintenance" ? .sshMaintenance :
            RuntimeStorage.Area(rawValue: suffix) ?? .vms
        let sentinel = fixture.storage.appending(path: "vms/unpublished")
        try Data("keep me".utf8).write(to: sentinel)
        if acl { try await fixture.addACL("everyone allow read,list", at: target) }
        else { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        #expect(throws: StorageFailure.protectionDrift) { _ = try storage.location(for: area) }
        #expect(throws: StorageFailure.protectionDrift) { _ = try storage.location(for: area) }
        // Explicit preparation restores only managed metadata; reuse itself never repairs.
        let reopened = try RuntimeStorage(root: fixture.storage)
        _ = try reopened.location(for: area)
        #expect(try Data(contentsOf: sentinel) == Data("keep me".utf8))
    }

    @Test(arguments: ["", "vms", "state", "ssh"])
    func staleBackupExclusionIsRefusedThenClearedOnExplicitPreparation(_ suffix: String) throws {
        let fixture = try Fixture()
        let storage = try RuntimeStorage(root: fixture.storage)
        let target = suffix.isEmpty ? fixture.storage : fixture.storage.appending(path: suffix)
        try RuntimeStorage.writeBackupExclusion(target, true)
        let area: RuntimeStorage.Area = suffix == "ssh" ? .sshMaintenance : .init(rawValue: suffix) ?? .vms
        #expect(throws: StorageFailure.protectionDrift) { _ = try storage.location(for: area) }
        #expect(try backupExcluded(target))
        let reopened = try RuntimeStorage(root: fixture.storage)
        #expect(try !backupExcluded(target))
        #expect(try backupExcluded(reopened.location(for: .staging)))
        #expect(try backupExcluded(reopened.location(for: .downloads)))
    }

    @Test func postMutationProtectionDriftIsRefused() throws {
        let fixture = try Fixture()
        #expect(throws: StorageFailure.protectionDrift) {
            _ = try RuntimeStorage(root: fixture.storage) { url, excluded in
                try RuntimeStorage.writeBackupExclusion(url, excluded)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.appending(path: "runtime").path))
    }

    @Test func opaquePreparationFailureIsFixedAndDoesNotDeleteExistingWork() throws {
        struct OpaqueFailure: Error {}
        let fixture = try Fixture()
        try fixture.directory(fixture.storage)
        let sentinel = fixture.storage.appending(path: "unpublished")
        try Data("keep me".utf8).write(to: sentinel)
        #expect(throws: StorageFailure.preparationFailed) {
            _ = try RuntimeStorage(root: fixture.storage) { _, _ in throw OpaqueFailure() }
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep me".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.appending(path: "runtime").path))
    }

    @Test func inheritedReadACLIsRemovedWithoutChangingTheContainingFolder() async throws {
        let fixture = try Fixture()
        try await fixture.addACL("everyone allow read,list,directory_inherit", at: fixture.base)
        let storage = try RuntimeStorage(root: fixture.storage)
        try StorageProtection.verify(fixture.storage)
        try StorageProtection.verify(storage.location(for: .sshMaintenance))
        #expect(throws: StorageFailure.protectionDrift) { try StorageProtection.verify(fixture.base) }
    }

    @Test func postMutationACLDriftIsRefused() async throws {
        let fixture = try Fixture()
        let donor = fixture.base.appending(path: "acl-donor")
        try fixture.directory(donor)
        try await fixture.addACL("everyone allow read,list", at: donor)
        #expect(throws: StorageFailure.protectionDrift) {
            _ = try RuntimeStorage(root: fixture.storage) { url, excluded in
                try RuntimeStorage.writeBackupExclusion(url, excluded)
                guard let acl = acl_get_file(donor.path, ACL_TYPE_EXTENDED) else { throw StorageFailure.inspectionFailed }
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                guard acl_set_link_np(url.path, ACL_TYPE_EXTENDED, acl) == 0 else { throw StorageFailure.preparationFailed }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.appending(path: "runtime").path))
    }

    @Test func changedDirectoryBindingAfterMetadataWriteIsRefused() throws {
        let fixture = try Fixture()
        let preserved = fixture.base.appending(path: "preserved")
        try fixture.directory(fixture.storage)
        try Data("keep me".utf8).write(to: fixture.storage.appending(path: "unpublished"))
        #expect(throws: StorageFailure.unsafeStructure) {
            _ = try RuntimeStorage(root: fixture.storage) { url, excluded in
                try RuntimeStorage.writeBackupExclusion(url, excluded)
                try FileManager.default.moveItem(at: url, to: preserved)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
        #expect(try Data(contentsOf: preserved.appending(path: "unpublished")) == Data("keep me".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path).isEmpty)
    }

    @Test func ignoredBackupPolicyIsRefused() throws {
        let fixture = try Fixture()
        #expect(throws: StorageFailure.protectionDrift) {
            _ = try RuntimeStorage(root: fixture.storage) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.appending(path: "downloads").path))
    }

    @Test(arguments: ["Library", "Library/Application Support/Guesthouse/runtime"])
    func finalPassRechecksEarlierPreparedComponents(_ suffix: String) throws {
        let fixture = try Fixture()
        let root = fixture.base.appending(path: "Library/Application Support/Guesthouse")
        #expect(throws: StorageFailure.protectionDrift) {
            _ = try RuntimeStorage(root: root) { url, excluded in
                try RuntimeStorage.writeBackupExclusion(url, excluded)
                if url.lastPathComponent == "maintenance" {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.base.appending(path: suffix).path)
                }
            }
        }
    }

    @Test func stickyContainingDirectoryRemainsSupported() throws {
        let fixture = try Fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: fixture.base.path)
        let storage = try RuntimeStorage(root: fixture.storage)
        _ = try storage.location(for: .vms)
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.base.path)[.posixPermissions] as? NSNumber)?.intValue == 0o1777)
    }

    @Test(arguments: [RuntimeStorage.Area.vms, .sshMaintenance]) func replacedLeafIsRefusedOnReuse(_ area: RuntimeStorage.Area) throws {
        let fixture = try Fixture()
        let storage = try RuntimeStorage(root: fixture.storage)
        let leaf = try storage.location(for: area), preserved = fixture.base.appending(path: "preserved")
        try Data("keep me".utf8).write(to: leaf.appending(path: "unpublished"))
        try FileManager.default.moveItem(at: leaf, to: preserved)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: preserved)
        #expect(throws: StorageFailure.unsafeStructure) { _ = try storage.location(for: area) }
        #expect(try Data(contentsOf: preserved.appending(path: "unpublished")) == Data("keep me".utf8))
    }

    @Test func unsafeMissingAncestorsAndInvalidPathsNeverCreateStorage() throws {
        let fixture = try Fixture()
        let dangling = fixture.base.appending(path: "dangling"), missing = fixture.base.appending(path: "missing")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        #expect(throws: StorageFailure.unsafeStructure) { _ = try RuntimeStorage(root: dangling.appending(path: "Guesthouse")) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let invalid = URL(fileURLWithPath: fixture.storage.path + "\0suffix")
        #expect(throws: StorageFailure.invalidLocation) { _ = try RuntimeStorage(root: invalid) }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.path))
    }

    @Test func defaultLocationIsResolvedWithoutPreparation() throws {
        #expect(try RuntimeStorage.defaultRoot().path.hasSuffix("/Library/Application Support/Guesthouse"))
    }

    private func backupExcluded(_ url: URL) throws -> Bool {
        try #require(URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup as Bool?)
    }
    private final class Fixture: Sendable {
        let base: URL
        var storage: URL { base.appending(path: "Guesthouse") }
        init() throws {
            var template = Array("/private/tmp/guesthouse-runtime-storage-XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else { throw StorageFailure.inspectionFailed }
            base = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) } // Only this mkdtemp-owned fixture.
        func directory(_ url: URL, mode: Int = 0o700) throws {
            if url == base { return }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
        }
        func addACL(_ rule: String, at url: URL) async throws {
            let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/chmod"),
                arguments: ["+a", rule, url.path], timeout: .seconds(5)))
            let report = try await run.waitForExit()
            try #require(try report.childExit?.get() == .status(0) && !report.timedOut && !report.canceled)
        }
    }
}
