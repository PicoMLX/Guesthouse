import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateFileEntryTests {
    let evidence = Data("retained fixture state".utf8)

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal])
    func missingReadsDoNotCreateFilesOrEnterTheBody(access: StateFileAccess) throws {
        let fixture = try Fixture()
        let result = try fixture.anchor.withFile(access, body: { _ in Issue.record("Missing file was opened"); return 1 })
        #expect(result == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal])
    func creationDuringMissingEntryValidationCannotPublishEmpty(access: StateFileAccess) throws {
        let fixture = try Fixture()
        var observed = false
        #expect(throws: access.failure) {
            try fixture.anchor.withDescriptor { directory in
                try StateFileEntry.withDescriptor(in: directory, access: access,
                    permissionBarrier: { _, _ in Issue.record("Missing file needed no repair") },
                    didObserve: { observed = true },
                    validateDirectory: { _ in try evidence.write(to: fixture.file(access)) },
                    body: { _ in Issue.record("Missing observation was retried"); return 1 })
            }
        }
        #expect(try Data(contentsOf: fixture.file(access)) == evidence)
        #expect(observed)
    }

    @Test(arguments: [false, true]) func journalCreationNeverTruncatesExistingBytes(existing: Bool) throws {
        let fixture = try Fixture()
        if existing { try evidence.write(to: fixture.file(.writeJournal)) }
        let bytes = try fixture.anchor.withFile(.writeJournal, body: { try StateFileIO.readAll($0, from: 0, name: .journal) })
        #expect(bytes == (existing ? evidence : Data()))
        #expect(try fixture.mode(.writeJournal) == 0o600)
    }

    @Test func requiredJournalDisappearanceCannotRecreateThroughAnchor() throws {
        let fixture = try Fixture(), file = fixture.file(.writeJournal)
        try evidence.write(to: file)
        #expect(try fixture.anchor.withFile(.writeJournal, requireExisting: true,
            body: { try StateFileIO.readAll($0, from: 0, name: .journal) }) == evidence)
        let detached = fixture.state.appending(path: "detached")
        try #require(rename(file.path, detached.path) == 0)
        for _ in 0..<2 {
            #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                try fixture.anchor.withFile(.writeJournal, requireExisting: true,
                    body: { _ in Issue.record("Recreated previously observed journal") })
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try Data(contentsOf: detached) == evidence)
        }
    }

    @Test(arguments: [(StateFileAccess.readSnapshot, Int32(O_RDONLY), "environments.json"),
                      (.readJournal, O_RDONLY, "journal.ndjson"), (.writeJournal, O_RDWR, "journal.ndjson")])
    func accessIsFixedNonblockingAndCloseOnExec(access: StateFileAccess, mode: Int32, name: String) throws {
        let fixture = try Fixture()
        #expect(access.name == name)
        try evidence.write(to: fixture.file(access))
        let bytes = try fixture.anchor.withFile(access, body: { fd in
            #expect(fcntl(fd, F_GETFL) & O_ACCMODE == mode)
            #expect(fcntl(fd, F_GETFL) & O_NONBLOCK != 0)
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
            return try StateFileIO.readAll(fd, from: 0, name: access.label)
        })
        #expect(bytes == evidence)
    }

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal, .writeJournal], [false, true])
    func finalSymlinksAreRefusedWithoutChangingDestinations(access: StateFileAccess, dangling: Bool) throws {
        let fixture = try Fixture()
        let target = fixture.state.appending(path: "outside")
        if !dangling { try evidence.write(to: target) }
        try FileManager.default.createSymbolicLink(at: fixture.file(access), withDestinationURL: target)
        #expect(throws: StateStoreError.insecureDirectory(reason: .symbolicLink)) {
            try fixture.anchor.withFile(access, body: { _ in Issue.record("Followed a symlink") })
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.file(access).path) == target.path)
        if !dangling { #expect(try Data(contentsOf: target) == evidence) }
    }

    @Test(arguments: StateFileAccess.allCases)
    func secondNamesAreRefusedBeforePermissionRepair(access: StateFileAccess) throws {
        let fixture = try Fixture()
        let file = fixture.file(access)
        try evidence.write(to: file)
        try #require(chmod(file.path, 0o666) == 0)
        try #require(link(file.path, fixture.state.appending(path: "alias").path) == 0)
        #expect(throws: StateStoreError.insecureDirectory(reason: .multipleLinks)) {
            try fixture.anchor.withFile(access, body: { _ in Issue.record("Opened a multiply linked file") })
        }
        #expect(try fixture.mode(access) == 0o666)
        #expect(try Data(contentsOf: file) == evidence)
    }

    @Test(arguments: StateFileAccess.allCases)
    func namedPipesAreRefusedWithoutWaitingForAPeer(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try #require(mkfifo(fixture.file(access).path, 0o600) == 0)
        #expect(throws: StateStoreError.insecureDirectory(reason: .notRegularFile)) {
            try fixture.anchor.withFile(access, body: { _ in Issue.record("Opened a FIFO") })
        }
    }

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal])
    func directoriesCannotBeReadAsStateFiles(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try #require(mkdir(fixture.file(access).path, 0o700) == 0)
        #expect(throws: StateStoreError.insecureDirectory(reason: .notRegularFile)) {
            try fixture.anchor.withFile(access, body: { _ in Issue.record("Opened a directory") })
        }
    }

    // Read paths repair private metadata under the same exclusive lock as their body. There
    // is no shared/exclusive conversion gap. Contention is tested with an independent open.
    @Test(arguments: StateFileAccess.allCases)
    func permissionBarrierAndBodyShareOneExclusiveLock(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        try #require(chmod(fixture.file(access).path, 0o666) == 0)
        let other = open(fixture.file(access).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(other >= 0)
        defer { close(other) }
        var barriers = 0
        _ = try fixture.anchor.withFile(access, permissionBarrier: { fd, label in
            barriers += 1
            try requireContended(other)
            try StateFileProtection.verify(fd, kind: .regularFile)
            #expect(label == access.label)
        }, body: { _ in try requireContended(other) })
        #expect(barriers == 1)
        try #require(flock(other, LOCK_EX | LOCK_NB) == 0)
        #expect(try Data(contentsOf: fixture.file(access)) == evidence)
    }

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal])
    func failedPermissionBarrierPreservesBytesAndRetryStillSynchronizes(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        try #require(chmod(fixture.file(access).path, 0o666) == 0)
        let failure = StateStoreError.fileUnwritable(name: access.label)
        var barriers = 0
        #expect(throws: failure) {
            try fixture.anchor.withFile(access, permissionBarrier: { _, _ in barriers += 1; throw failure },
                body: { _ in Issue.record("Accepted an unsynchronized repair") })
        }
        #expect(try fixture.mode(access) == 0o600)
        let bytes = try fixture.anchor.withFile(access, permissionBarrier: { _, _ in barriers += 1 },
            body: { try StateFileIO.readAll($0, from: 0, name: access.label) })
        #expect(barriers == 2)
        #expect(bytes == evidence)
    }

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal])
    func repeatedPrivateReadsPreserveTheFileVersionNeededByTheReplayCache(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        let descriptor = open(fixture.file(access).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        // An explicitly empty restored ACL must not force metadata rewrites on every open.
        let empty = try #require(acl_init(0))
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        try #require(acl_set_fd(descriptor, empty) == 0)
        let first = try fixture.anchor.withFile(access, body: { try StateFileIO.version($0, name: access.label) })
        let second = try fixture.anchor.withFile(access, body: { try StateFileIO.version($0, name: access.label) })
        #expect(first == second)
    }

    @Test(arguments: StateFileAccess.allCases)
    func fileReplacementDuringPermissionBarrierIsRefused(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        let detached = fixture.state.appending(path: "detached")
        #expect(throws: StateStoreError.fileUnwritable(name: access.label)) {
            try fixture.anchor.withFile(access, permissionBarrier: { _, _ in
                try #require(rename(fixture.file(access).path, detached.path) == 0)
                try Data("replacement".utf8).write(to: fixture.file(access))
            }, body: { _ in Issue.record("Accepted a changed entry") })
        }
        #expect(try Data(contentsOf: detached) == evidence)
    }

    @Test(arguments: StateFileAccess.allCases)
    func sameInodeReattachmentDuringPermissionBarrierIsRefused(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        let detached = fixture.state.appending(path: "detached")
        #expect(throws: StateStoreError.fileUnwritable(name: access.label)) {
            try fixture.anchor.withFile(access, permissionBarrier: { _, _ in
                try #require(rename(fixture.file(access).path, detached.path) == 0)
                try #require(rename(detached.path, fixture.file(access).path) == 0)
            }, body: { _ in Issue.record("Accepted a reattached entry") })
        }
        #expect(try Data(contentsOf: fixture.file(access)) == evidence)
    }

    @Test func directoryReplacementDuringPermissionBarrierIsRefused() throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(.readJournal))
        let detached = fixture.base.appending(path: "detached")
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try fixture.anchor.withFile(.readJournal, permissionBarrier: { _, _ in
                try #require(rename(fixture.state.path, detached.path) == 0)
                try #require(mkdir(fixture.state.path, 0o700) == 0)
            }, body: { _ in Issue.record("Accepted a detached directory") })
        }
        #expect(try Data(contentsOf: detached.appending(path: "journal.ndjson")) == evidence)
    }

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal])
    func changedReadVersionCannotReturnAResult(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        var accepted: Data?
        #expect(throws: StateStoreError.fileUnwritable(name: access.label)) {
            accepted = try fixture.anchor.withFile(access, body: { fd in
                let data = try StateFileIO.readAll(fd, from: 0, name: access.label)
                let detached = fixture.state.appending(path: "detached")
                try #require(rename(fixture.file(access).path, detached.path) == 0)
                try #require(rename(detached.path, fixture.file(access).path) == 0)
                return data
            })
        }
        #expect(accepted == nil)
        #expect(try Data(contentsOf: fixture.file(access)) == evidence)
    }

    @Test(arguments: [false, true])
    func journalWriteRejectsNamespaceChangesButAllowsContentWrites(reattach: Bool) throws {
        let fixture = try Fixture(), file = fixture.file(.writeJournal)
        try evidence.write(to: file)
        let detached = fixture.state.appending(path: "detached")
        let conflicting = fixture.state.appending(path: "conflicting")
        let otherEvidence = Data("conflicting journal history".utf8)
        let appended = Data(" appended record".utf8)
        let borrow = {
            try fixture.anchor.withFile(.writeJournal, body: { fd in
                try #require(lseek(fd, 0, SEEK_END) >= 0)
                try StateFileIO.writeAll(fd, appended, name: .journal)
                if reattach {
                    try #require(rename(file.path, detached.path) == 0)
                    try otherEvidence.write(to: file)
                    try #require(rename(file.path, conflicting.path) == 0)
                    try #require(rename(detached.path, file.path) == 0)
                }
            })
        }
        if reattach {
            #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) { try borrow() }
            #expect(try Data(contentsOf: conflicting) == otherEvidence)
        } else { try borrow() }
        #expect(try Data(contentsOf: file) == evidence + appended)
    }

    @Test func failedBorrowedWritePreservesEvidenceAndItsTypedUncertainty() throws {
        let fixture = try Fixture()
        let failure = StateStoreError.journalWriteUncertain(cause: .fileUnwritable(name: .journal))
        #expect(throws: failure) {
            try fixture.anchor.withFile(.writeJournal, body: { fd in
                try StateFileIO.writeAll(fd, evidence, name: .journal)
                throw failure
            })
        }
        #expect(try Data(contentsOf: fixture.file(.readJournal)) == evidence)
        // A second borrow succeeds: throwing released the first descriptor and lock.
        #expect(try fixture.anchor.withFile(.readJournal, body: { try StateFileIO.readAll($0, from: 0, name: .journal) }) == evidence)
    }

    @Test(arguments: StateFileAccess.allCases)
    func arbitraryBodyExceptionsRemainClosed(access: StateFileAccess) throws {
        enum Failure: Error { case interrupted }
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        #expect(throws: access.failure) {
            try fixture.anchor.withFile(access, body: { _ in throw Failure.interrupted })
        }
        #expect(try Data(contentsOf: fixture.file(access)) == evidence)
    }

    @Test(arguments: StateFileAccess.allCases)
    func observationSurvivesPreBodyProtectionFailure(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        var original = stat()
        try #require(lstat(fixture.file(access).path, &original) == 0)
        var identity: StateFileIdentity?
        var observations = 0
        let failure = StateStoreError.fileUnwritable(name: access.label)
        #expect(throws: failure) {
            try fixture.anchor.withFile(access, permissionBarrier: { _, _ in throw failure },
                didOpen: { observations += 1 }, didIdentify: { identity = $0; return true },
                body: { _ in Issue.record("Reached body after failed protection") })
        }
        #expect(observations == 1)
        #expect(identity == StateFileIdentity(original))
        #expect(try Data(contentsOf: fixture.file(access)) == evidence)
    }

    @Test(arguments: StateFileAccess.allCases)
    func deniedOpenIsObservedWithoutRepair(access: StateFileAccess) throws {
        let fixture = try Fixture()
        try evidence.write(to: fixture.file(access))
        var original = stat()
        try #require(lstat(fixture.file(access).path, &original) == 0)
        var identity: StateFileIdentity?
        try #require(chmod(fixture.file(access).path, 0) == 0)
        var observed = 0, opened = 0
        #expect(throws: access.failure) {
            try fixture.anchor.withFile(access, didOpen: { opened += 1 },
                didObserve: { observed += 1 }, didIdentify: { identity = $0; return true },
                body: { _ in Issue.record("Denied file reached body") })
        }
        #expect(observed == 1 && opened == 0)
        #expect(identity == StateFileIdentity(original))
        #expect(try fixture.mode(access) == 0)
        try #require(chmod(fixture.file(access).path, 0o600) == 0)
        #expect(try Data(contentsOf: fixture.file(access)) == evidence)
    }

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal], [false, true])
    func deniedReadClassificationRetainsPreOpenNamespace(access: StateFileAccess, replace: Bool) throws {
        let fixture = try Fixture(), file = fixture.file(access)
        let detached = fixture.base.appending(path: "denied-original")
        let replacement = fixture.base.appending(path: "replacement")
        let other = Data("distinct readable evidence".utf8)
        try evidence.write(to: file)
        try other.write(to: replacement)
        try #require(chmod(replacement.path, 0o600) == 0)
        try #require(chmod(file.path, 0) == 0)
        defer { _ = chmod(file.path, 0o600); _ = chmod(detached.path, 0o600) }
        var observed = 0, opened = 0
        let failure = StateStoreError.insecureDirectory(reason: replace ? .changed : .permissions)
        #expect(throws: failure) {
            try fixture.anchor.withFile(access, protection: .verifyOnly,
                permissionBarrier: { _, _ in Issue.record("Inspection must not repair protection") },
                didOpen: { opened += 1 }, didObserve: {
                    observed += 1
                    if replace {
                        #expect(rename(file.path, detached.path) == 0)
                        #expect(rename(replacement.path, file.path) == 0)
                    }
                }, body: { _ in Issue.record("Denied open must not enter the body") })
        }
        #expect(observed == 1 && opened == 0)
        let retained = replace ? detached : file
        var info = stat()
        try #require(lstat(retained.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0)
        try #require(chmod(retained.path, 0o600) == 0)
        #expect(try Data(contentsOf: retained) == evidence)
        #expect(try Data(contentsOf: replace ? file : replacement) == other)
        #expect(try fixture.mode(access) == 0o600)
    }

    private func requireContended(_ descriptor: Int32) throws {
        let result = flock(descriptor, LOCK_EX | LOCK_NB), failure = errno
        try #require(result == -1 && failure == EWOULDBLOCK)
    }

    private final class Fixture {
        let base: URL
        let anchor: StateDirectoryAnchor
        var state: URL { base.appending(path: "Guesthouse/state") }
        func file(_ access: StateFileAccess) -> URL { state.appending(path: access.name) }

        init() throws {
            let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-state-access-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let anchor: StateDirectoryAnchor
            do { anchor = try StateDirectoryAnchor(storage: RuntimeStorage(root: base.appending(path: "Guesthouse"))) }
            catch { try? FileManager.default.removeItem(at: base); throw error }
            self.base = base
            self.anchor = anchor
        }

        func mode(_ access: StateFileAccess) throws -> mode_t {
            var info = stat()
            try #require(lstat(file(access).path, &info) == 0)
            return info.st_mode & 0o7777
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
