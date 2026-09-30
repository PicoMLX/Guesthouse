import Darwin
import Dispatch
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct FreshStorageSetupTests {
    @Test func createsSelectedPrivateStorageAndRetainsOwnershipThroughReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try await fixture.create()
        let snapshot = try await store.loadSnapshot()
        #expect(snapshot.environments.isEmpty)
        #expect(snapshot.storageSelection?.volumeID == (try SystemStorageProbe.identifyVolume(atExistingDirectory: fixture.root.appending(path: "vms"))))
        #expect(try await store.replay().records.isEmpty)
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { try await fixture.open() }
        await store.close()
        let reopened = try await fixture.open()
        #expect(try await reopened.loadSnapshot() == snapshot)
        await reopened.close()
    }

    @Test func competingFirstSetupHasExactlyOneOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owners = await withTaskGroup(of: StateStore?.self, returning: [StateStore].self) { group in
            for _ in 0..<4 { group.addTask { try? await fixture.create() } }
            var owners: [StateStore] = []
            for await owner in group { if let owner { owners.append(owner) } }
            return owners
        }
        #expect(owners.count == 1)
        for owner in owners { await owner.close() }
    }

    @Test func ordinaryOpenCannotAcquireCompletedLayoutBeforeSetupHandsOffItsLock() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let setup = Task {
            try await fixture.create(backup: { url, excluded in
                try RuntimeStorage.writeBackupExclusion(url, excluded)
                if url.lastPathComponent == "maintenance" {
                    signal.yield(())
                    // The fixture blocks only StateStore's dedicated filesystem queue.
                    release.wait()
                }
            })
        }
        for await _ in entered { break }
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { try await fixture.open() }
        release.signal()
        signal.finish()
        let owner = try await setup.value
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { try await fixture.open() }
        await owner.close()
    }

    @Test(arguments: ["empty", "partial", "prepared", "link", "file"])
    func existingRootsAreNeverRepairedOrReplaced(kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let evidence = Data("unpublished work".utf8)
        switch kind {
        case "prepared":
            _ = try RuntimeStorage(root: fixture.root)
            try evidence.write(to: fixture.root.appending(path: "vms/disk"))
        case "link": try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: fixture.base.appending(path: "missing"))
        case "file": try evidence.write(to: fixture.root)
        default:
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            if kind == "partial" { try evidence.write(to: fixture.root.appending(path: "interrupted")) }
        }
        var before = stat(), after = stat()
        try #require(lstat(fixture.root.path, &before) == 0)
        await #expect(throws: StateStoreError.setupRequiresInspection) { try await fixture.create() }
        try #require(lstat(fixture.root.path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_mode == after.st_mode)
        if kind == "prepared" { #expect(try Data(contentsOf: fixture.root.appending(path: "vms/disk")) == evidence) }
        if kind == "partial" { #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["interrupted"]) }
        if kind == "file" { #expect(try Data(contentsOf: fixture.root) == evidence) }
    }

    @Test(arguments: ["layout", "snapshot"])
    func interruptedSetupIsPreservedAndCannotBeRetriedBlindly(stage: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hooks = StateStoreHooks(write: { fd, bytes in
            if stage == "snapshot" { throw StateStoreError.fileUnwritable(name: .snapshot) }
            try StateFileIO.writeAll(fd, bytes, name: .snapshot)
        })
        await #expect(throws: StateStoreError.self) {
            try await StateStore.createFresh(root: { fixture.root }, backup: { url, excluded in
                if stage == "layout", url.lastPathComponent == "vms" { throw StorageFailure.preparationFailed }
                try RuntimeStorage.writeBackupExclusion(url, excluded)
            }, hooks: hooks)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        await #expect(throws: StateStoreError.setupRequiresInspection) { try await fixture.create() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == names)
        if stage == "snapshot" {
            let reopened = try await fixture.open() // Failure released the owner, not its files.
            #expect(try await reopened.loadSnapshot().storageSelection == nil)
            await reopened.close()
        }
    }

    @Test func loaderSetupIsExplicitAndConcurrentRequestsCannotCreateTwice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let calls = Mutex(0)
        let loader = RuntimeStateLoader(open: fixture.open, create: { () async throws(StateStoreError) -> StateStore in
            calls.withLock { $0 += 1 }
            return try await fixture.create()
        })
        #expect(await loader.prepareStorage() == .loading)
        #expect(calls.withLock { $0 } == 0)
        await loader.load()
        #expect(loader.status == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = await loader.prepareStorage() } }
        }
        #expect(loader.status == .loaded)
        #expect(calls.withLock { $0 } == 1)
        #expect(loader.loadedState?.snapshot.storageSelection != nil)
        #expect(await loader.prepareStorage() == .loaded)
        #expect(calls.withLock { $0 } == 1)
        await loader.loadedState?.store.close()
    }

    @Test func loaderFailureRequiresInspectionAndDoesNotRetryCreation() async throws {
        let calls = Mutex(0)
        let loader = RuntimeStateLoader(open: { () async throws(StateStoreError) -> StateStore in throw .fileUnreadable(name: .stateDirectory) }, create: { () async throws(StateStoreError) -> StateStore in
            calls.withLock { $0 += 1 }
            throw .setupRequiresInspection
        })
        await loader.load()
        #expect(await loader.prepareStorage() == .repairRequired)
        #expect(await loader.prepareStorage() == .repairRequired)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func loadedUnselectedStorageRequiresExplicitSelectionAndPreservesOrphanWork(hasWork: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try RuntimeStorage(root: fixture.root)
        let disk = fixture.root.appending(path: "vms/task-disk")
        let work = Data("unpublished work".utf8)
        if hasWork { try work.write(to: disk) }
        let loader = RuntimeStateLoader(open: fixture.open)
        await loader.load()
        #expect(loader.loadedState?.snapshot.storageSelection == nil)
        #expect(await loader.prepareStorage() == (hasWork ? .repairRequired : .loaded))
        #expect((loader.loadedState?.snapshot.storageSelection != nil) == !hasWork)
        if hasWork { #expect(try Data(contentsOf: disk) == work) }
        await loader.loadedState?.store.close()
    }

    private struct Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-fresh-\(UUID())")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        func create(backup: @escaping RuntimeStorage.BackupWriter = RuntimeStorage.writeBackupExclusion) async throws(StateStoreError) -> StateStore {
            try await StateStore.createFresh(root: { root }, backup: backup)
        }
        func open() async throws(StateStoreError) -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(existingRoot: root) })
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
