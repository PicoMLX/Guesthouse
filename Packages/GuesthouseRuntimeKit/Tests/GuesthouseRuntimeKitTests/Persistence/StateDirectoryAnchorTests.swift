import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateDirectoryAnchorTests {
    @Test func ownsOnlyTheFixedPrivateStateDirectoryAndCreatesNoFiles() throws {
        let fixture = try Fixture()
        var requested: String?, flags: Int32 = 0
        let anchor = try StateDirectoryAnchor(storage: fixture.storage, openDirectory: { path, options in
            requested = path; flags = options
            return open(path, options)
        })
        #expect(requested == fixture.state.path)
        #expect(flags == O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let version = try anchor.verifyCurrent()
        try anchor.withDescriptor { fd in
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
            #expect(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY)
            let borrowedVersion = try StateFileIO.version(fd, name: .stateDirectory)
            #expect(borrowedVersion == version)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test func failedOpenDoesNotTransferOrCloseOwnership() throws {
        let fixture = try Fixture()
        var closes = 0
        #expect(throws: StateStoreError.insecureDirectory(reason: .unopenable)) {
            _ = try StateDirectoryAnchor(storage: fixture.storage, openDirectory: { _, _ in -1 },
                                         closeDirectory: { _ in closes += 1 })
        }
        #expect(closes == 0)
    }

    @Test func initializationRejectsReplacedBindingAndClosesExactlyOnce() throws {
        let fixture = try Fixture()
        var closes = 0
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            _ = try StateDirectoryAnchor(storage: fixture.storage, openDirectory: { path, options in
                let fd = open(path, options)
                #expect(fd >= 0)
                #expect(rename(path, fixture.detached.path) == 0)
                #expect(mkdir(path, 0o700) == 0)
                return fd
            }, closeDirectory: { fd in closes += 1; close(fd) })
        }
        #expect(closes == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.detached.path))
    }

    @Test(arguments: [false, true])
    func preOpenReplacementCannotBecomeTheObservedDirectory(populated: Bool) throws {
        let fixture = try Fixture(), replacement = try Fixture()
        let original = Data("original retained inventory".utf8)
        let other = Data("different retained inventory".utf8)
        try original.write(to: fixture.state.appending(path: "evidence"))
        if populated { try other.write(to: replacement.state.appending(path: "evidence")) }
        var opens = 0, closes = 0
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            _ = try StateDirectoryAnchor(storage: fixture.storage, openDirectory: { path, flags in
                opens += 1
                #expect(rename(path, fixture.detached.path) == 0)
                #expect(rename(replacement.state.path, path) == 0)
                return open(path, flags)
            }, closeDirectory: { fd in closes += 1; close(fd) })
        }
        #expect(opens == 1 && closes == 1)
        #expect(try Data(contentsOf: fixture.detached.appending(path: "evidence")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path) ==
                (populated ? ["evidence"] : []))
        if populated { #expect(try Data(contentsOf: fixture.state.appending(path: "evidence")) == other) }
    }

    @Test func successfulOwnerClosesExactlyOnceOnReleaseNotAfterBorrowing() throws {
        let fixture = try Fixture()
        var closes = 0
        var anchor: StateDirectoryAnchor? = try StateDirectoryAnchor(storage: fixture.storage,
            closeDirectory: { fd in closes += 1; close(fd) })
        weak let observer = anchor
        try anchor?.withDescriptor { fd in #expect(fcntl(fd, F_GETFD) >= 0) }
        #expect(closes == 0)
        anchor = nil
        #expect(observer == nil)
        #expect(closes == 1)
        // No post-close fcntl assertion: parallel tests may already have reused that integer.
    }

    @Test func missingDirectoryIsRefusedWithoutRecreationOrEnteringBody() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        try #require(rmdir(fixture.state.path) == 0)
        var entered = false
        #expect(throws: StateStoreError.insecureDirectory(reason: .unreadable)) {
            try anchor.withDescriptor { _ in entered = true }
        }
        #expect(!entered)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
    }

    @Test func replacementDirectoryIsRefusedAndBothCopiesArePreserved() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        let evidence = Data("unpublished fixture work".utf8)
        try evidence.write(to: fixture.state.appending(path: "evidence"))
        try #require(rename(fixture.state.path, fixture.detached.path) == 0)
        try #require(mkdir(fixture.state.path, 0o700) == 0)
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try anchor.verifyCurrent() }
        #expect(try Data(contentsOf: fixture.detached.appending(path: "evidence")) == evidence)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test func finalSymlinkBackToTheOwnedInodeIsStillRefused() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        try #require(rename(fixture.state.path, fixture.detached.path) == 0)
        try FileManager.default.createSymbolicLink(at: fixture.state, withDestinationURL: fixture.detached)
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try anchor.verifyCurrent() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.state.path) == fixture.detached.path)
    }

    @Test(arguments: ["state", ""])
    func managedModeDriftIsRefusedWithoutRepair(suffix: String) throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        let target = suffix.isEmpty ? fixture.root : fixture.root.appending(path: suffix)
        try #require(chmod(target.path, 0o755) == 0)
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) { try anchor.verifyCurrent() }
        var info = stat()
        try #require(lstat(target.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o755)
    }

    @Test func unsafeAncestorIsRefusedEvenWhenTheOwnedDirectoryIsUnchanged() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        try #require(chmod(fixture.base.path, 0o777) == 0)
        defer { chmod(fixture.base.path, 0o700) }
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try anchor.verifyCurrent() }
    }

    @Test(arguments: ["state", ""])
    func backupPolicyDriftIsRefusedWithoutRepair(suffix: String) throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        let target = suffix.isEmpty ? fixture.root : fixture.root.appending(path: suffix)
        try RuntimeStorage.writeBackupExclusion(target, true)
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) { try anchor.verifyCurrent() }
        let fresh = URL(fileURLWithPath: target.path)
        #expect(try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func postBorrowProtectionDriftRefusesResultWithoutPretendingToUndoWork() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        var returned: Int?
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
            returned = try anchor.withDescriptor { fd in
                try #require(fchmod(fd, 0o755) == 0)
                return 42
            }
        }
        #expect(returned == nil)
        var info = stat()
        try #require(lstat(fixture.state.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o755)
    }

    @Test func borrowedWorkFailuresStayClosedAndDoNotRetireTheOwner() throws {
        enum Failure: Error { case interrupted }
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        let uncertain = StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))
        #expect(throws: uncertain) { try anchor.withDescriptor { _ in throw uncertain } }
        #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) {
            try anchor.withDescriptor { _ in throw Failure.interrupted }
        }
        try anchor.verifyCurrent()
    }

    // Retains the directory half of StateStorePublicationReattachmentTests. Full snapshot and
    // uncertain-journal result/evidence tests still belong to the not-yet-migrated actor.
    @Test func sameInodeReattachmentAcrossABarrierInvalidatesPublicationVersion() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        let before = try anchor.verifyCurrent()
        try #require(rename(fixture.state.path, fixture.detached.path) == 0)
        let parent = open(fixture.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(parent >= 0)
        defer { close(parent) }
        try StateFileIO.fullySynchronize(parent, name: .stateDirectory)
        try #require(rename(fixture.detached.path, fixture.state.path) == 0)
        let after = try anchor.verifyCurrent()
        try #require(before.identity == after.identity)
        try #require(before != after)
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try anchor.verifyCurrent(version: before)
        }
    }

    @Test func ordinaryDirectoryChangesCanBeAcceptedWithFreshVersionEvidence() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage)
        let before = try anchor.verifyCurrent()
        try anchor.withDescriptor { fd in
            let file = openat(fd, "fixture", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try #require(file >= 0)
            close(file)
        }
        let after = try anchor.verifyCurrent()
        #expect(before.identity == after.identity)
        try anchor.verifyCurrent(version: after)
    }

    @Test func safeAncestorAliasDoesNotChangeTheManagedSelection() throws {
        let fixture = try Fixture()
        let alias = fixture.base.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.base)
        let storage = try RuntimeStorage(root: alias.appending(path: "Guesthouse"))
        let anchor = try StateDirectoryAnchor(storage: storage)
        let direct = try StateDirectoryAnchor(storage: fixture.storage)
        #expect(try anchor.verifyCurrent().identity == direct.verifyCurrent().identity)
    }

    private final class Fixture {
        let base: URL
        let storage: RuntimeStorage
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var detached: URL { root.appending(path: "detached") }

        init() throws {
            let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-state-anchor-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let storage: RuntimeStorage
            do { storage = try RuntimeStorage(root: base.appending(path: "Guesthouse")) }
            catch { try? FileManager.default.removeItem(at: base); throw error }
            self.base = base
            self.storage = storage
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
