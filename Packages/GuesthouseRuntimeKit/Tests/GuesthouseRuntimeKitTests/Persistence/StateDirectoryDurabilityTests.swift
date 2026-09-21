import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateDirectoryDurabilityTests {
    @Test func physicalAndLexicalParentsHaveIndependentRootOutwardCoverage() {
        #expect(StateDirectoryDurability.parents(lexical: "/links/alias/project/state", physical: "/data/project/state")
            == ["/", "/data", "/data/project", "/links", "/links/alias", "/links/alias/project"])
        #expect(StateDirectoryDurability.parents(lexical: "/data/project/state", physical: "/data/project/state")
            == ["/", "/data", "/data/project"])
    }

    // Adapts the retained StateStoreRecoveryTests ancestry cases to fixed RuntimeStorage.
    @Test(arguments: [false, true], [false, true])
    func existingAncestryIsResynchronizedBeforeAcceptance(throughSymlink: Bool, existingLeaf: Bool) throws {
        let fixture = try Fixture(existingLeaf: existingLeaf)
        let storage = try fixture.storage(throughSymlink: throughSymlink)
        let anchor = try StateDirectoryAnchor(storage: storage)
        var synchronized: [StateFileIdentity] = []
        try anchor.synchronizePreparation { fd, name in
            #expect(name == .stateDirectory)
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
            synchronized.append(try identity(fd))
        }
        let stateID = try fixture.identity(fixture.state)
        #expect(synchronized.first == stateID)
        let ancestorIDs = try [fixture.base, fixture.actual, fixture.root].map { try fixture.identity($0) }
        let firstIndices = try ancestorIDs.map { try #require(synchronized.firstIndex(of: $0)) }
        #expect(firstIndices == firstIndices.sorted())
        #expect(firstIndices.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test(arguments: [mode_t(0o100), mode_t(0o300)], [false, true])
    func searchOnlyAncestorsRetainDescriptorChecksAndBarriers(mode: mode_t, throughSymlink: Bool) throws {
        let fixture = try Fixture(existingLeaf: true)
        try #require(chmod(fixture.actual.path, mode) == 0)
        defer { _ = chmod(fixture.actual.path, 0o700) }
        let storage = try fixture.storage(throughSymlink: throughSymlink)
        let anchor = try StateDirectoryAnchor(storage: storage)
        let expected = try fixture.identity(fixture.actual)
        var visits = 0
        try anchor.synchronizePreparation { fd, name in
            if try identity(fd) == expected {
                visits += 1
                #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
                var info = stat()
                try #require(fstat(fd, &info) == 0)
                #expect(info.st_mode & 0o777 == mode)
            }
            try StateFileIO.fullySynchronize(fd, name: name)
        }
        #expect(visits >= 1)
        let failure = StateStoreError.fileUnwritable(name: .stateDirectory)
        #expect(throws: failure) {
            try StateDirectoryDurability.synchronize(fixture.actual.path) { _, _ in throw failure }
        }
        var after = stat()
        try #require(stat(fixture.actual.path, &after) == 0)
        #expect(after.st_mode & 0o777 == mode)
        try anchor.verifyCurrent()
    }

    @Test func aSecondPreparationRepeatsAllBarriersWithoutCachingVisibleSuccess() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage())
        var first: [StateFileIdentity] = [], second: [StateFileIdentity] = []
        try anchor.synchronizePreparation { fd, _ in first.append(try identity(fd)) }
        try anchor.synchronizePreparation { fd, _ in second.append(try identity(fd)) }
        #expect(first == second)
        #expect(first.count > 3)
    }

    @Test func failedLeafBarrierStopsBeforeAnyAncestorAndPreservesEvidence() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage())
        let evidence = Data("unconfirmed fixture operation".utf8)
        let file = fixture.state.appending(path: "evidence")
        try evidence.write(to: file)
        var barriers = 0
        let failure = StateStoreError.fileUnwritable(name: .stateDirectory)
        #expect(throws: failure) {
            try anchor.synchronizePreparation { _, _ in barriers += 1; throw failure }
        }
        #expect(barriers == 1)
        #expect(try Data(contentsOf: file) == evidence)
    }

    @Test func failedAncestorBarrierPreservesWorkAndRetryStartsFromTheLeaf() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage())
        let evidence = Data("unpublished fixture work".utf8)
        let file = fixture.state.appending(path: "evidence")
        try evidence.write(to: file)
        let failedParent = try fixture.identity(fixture.root)
        let failure = StateStoreError.fileUnwritable(name: .stateDirectory)
        var first: [StateFileIdentity] = [], retry: [StateFileIdentity] = []
        #expect(throws: failure) {
            try anchor.synchronizePreparation { fd, _ in
                let current = try identity(fd)
                first.append(current)
                if current == failedParent { throw failure }
            }
        }
        try anchor.synchronizePreparation { fd, _ in retry.append(try identity(fd)) }
        #expect(first.last == failedParent)
        #expect(retry.starts(with: first))
        #expect(try Data(contentsOf: file) == evidence)
    }

    @Test(arguments: ["state", ""])
    func policyDriftDuringBarrierRefusesAcceptanceWithoutRepair(suffix: String) throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage())
        let target = suffix.isEmpty ? fixture.root : fixture.root.appending(path: suffix)
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
            try anchor.synchronizePreparation { _, _ in try #require(chmod(target.path, 0o755) == 0) }
        }
        var current = stat()
        try #require(lstat(target.path, &current) == 0)
        #expect(current.st_mode & 0o7777 == 0o755)
    }

    @Test func replacingTheStateDuringItsBarrierRefusesAcceptance() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage())
        let detached = fixture.root.appending(path: "detached")
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try anchor.synchronizePreparation { _, _ in
                try #require(rename(fixture.state.path, detached.path) == 0)
                try #require(mkdir(fixture.state.path, 0o700) == 0)
            }
        }
        #expect(FileManager.default.fileExists(atPath: detached.path))
    }

    @Test func sameInodeStateReattachmentDuringBarrierIsRefused() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage())
        let detached = fixture.root.appending(path: "detached")
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try anchor.synchronizePreparation { _, _ in
                try #require(rename(fixture.state.path, detached.path) == 0)
                try #require(rename(detached.path, fixture.state.path) == 0)
            }
        }
        try anchor.verifyCurrent()
    }

    @Test func ancestorDescriptorBindingIsRecheckedAfterTheBarrier() throws {
        let fixture = try Fixture()
        let detached = fixture.base.appending(path: "detached")
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try StateDirectoryDurability.synchronize(fixture.actual.path) { _, _ in
                try #require(rename(fixture.actual.path, detached.path) == 0)
                try #require(mkdir(fixture.actual.path, 0o700) == 0)
            }
        }
        #expect(FileManager.default.fileExists(atPath: detached.path))
    }

    @Test func unrelatedSiblingEntriesDoNotInvalidateAnAncestorBarrier() throws {
        let fixture = try Fixture()
        let sibling = fixture.actual.appending(path: "sibling")
        try StateDirectoryDurability.synchronize(fixture.actual.path) { _, _ in
            try #require(mkdir(sibling.path, 0o700) == 0)
        }
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test func arbitraryBarrierExceptionsUseClosedFailures() throws {
        enum Failure: Error { case interrupted }
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage())
        #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) {
            try anchor.synchronizePreparation { _, _ in throw Failure.interrupted }
        }
        #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) {
            try StateDirectoryDurability.synchronize(fixture.actual.path) { _, _ in throw Failure.interrupted }
        }
    }

    @Test func nativeBarriersCompleteWithoutCreatingStateFiles() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: fixture.storage(throughSymlink: true))
        try anchor.synchronizePreparation()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
        try anchor.verifyCurrent()
    }

    private func identity(_ descriptor: Int32) throws -> StateFileIdentity {
        var info = stat()
        try #require(fstat(descriptor, &info) == 0)
        return StateFileIdentity(info)
    }

    private final class Fixture {
        let base: URL
        var actual: URL { base.appending(path: "actual") }
        var root: URL { actual.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }

        init(existingLeaf: Bool = false) throws {
            let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-state-durability-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            do {
                try FileManager.default.createDirectory(at: base.appending(path: existingLeaf ? "actual/Guesthouse/state" : "actual"),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { try? FileManager.default.removeItem(at: base); throw error }
            self.base = base
        }

        func storage(throughSymlink: Bool = false) throws -> RuntimeStorage {
            if throughSymlink {
                let alias = base.appending(path: "alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
                return try RuntimeStorage(root: alias.appending(path: "Guesthouse"))
            }
            return try RuntimeStorage(root: root)
        }

        func identity(_ url: URL) throws -> StateFileIdentity {
            var info = stat()
            try #require(stat(url.path, &info) == 0)
            return StateFileIdentity(info)
        }

        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
