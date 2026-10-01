import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct LumeProbeStorageTests {
    private final class Fixture: Sendable {
        let base, root, configuration: URL
        let storage: RuntimeStorage
        init() async throws {
            var template = Array("/private/tmp/guesthouse-lume-paths-XXXXXX".utf8CString)
            let name = try #require(mkdtemp(&template))
            base = URL(fileURLWithPath: String(cString: name))
            root = base.appending(path: "Guesthouse")
            configuration = root.appending(path: "state/lume-xdg")
            let freshRoot = root
            let owner = try await StateStore.createFresh(root: { freshRoot })
            storage = try RuntimeStorage(existingRoot: root)
            await owner.close()
        }
        deinit { try? FileManager.default.removeItem(at: base) }

        func owner() async throws -> StateStore {
            let root = root
            return try await StateStore.open(storage: { try RuntimeStorage(existingRoot: root) })
        }
    }

    @Test func ordinaryReopeningDoesNotRequireOrCreateCandidateConfiguration() async throws {
        let fixture = try await Fixture()
        _ = try RuntimeStorage(existingRoot: fixture.root)
        let owner = try await fixture.owner()
        #expect(try await owner.loadSnapshot().environments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
        #expect(throws: StorageFailure.inspectionFailed) { _ = try fixture.storage.environmentForLumeProbe() }
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
        await owner.close()
    }

    @Test func explicitOwnedSetupUsesOnlyFixedPrivateEnvironmentAndPreservesWork() async throws {
        let fixture = try await Fixture(), owner = try await fixture.owner()
        let disk = fixture.root.appending(path: "vms/unpublished")
        try Data("saved work".utf8).write(to: disk)
        try await owner.prepareLumeProbeConfiguration()
        let environment = try fixture.storage.environmentForLumeProbe()
        #expect(environment == [
            "LUME_TELEMETRY_ENABLED": "false", "LUME_UPDATE_CHECK": "false",
            "TMPDIR": fixture.root.appending(path: "staging").path,
            "XDG_CONFIG_HOME": fixture.configuration.path,
        ])
        #expect(environment["HOME"] == nil && environment["PATH"] == nil)
        try StorageProtection.verify(fixture.configuration)
        #expect(try fixture.configuration.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
        let identity = StateFileIdentity(try StorageProtection.structure(fixture.configuration))
        let saved = fixture.configuration.appending(path: "saved-config")
        try Data("keep configuration".utf8).write(to: saved)
        try await owner.prepareLumeProbeConfiguration()
        #expect(StateFileIdentity(try StorageProtection.structure(fixture.configuration)) == identity)
        #expect(try Data(contentsOf: saved) == Data("keep configuration".utf8))
        #expect(try Data(contentsOf: disk) == Data("saved work".utf8))
        await owner.close()
    }

    @Test(arguments: ["", "vms", "state", "state/lume-xdg", "staging"], [false, true])
    func eachWritableComponentIsRecheckedWithoutRepair(_ suffix: String, _ acl: Bool) async throws {
        let fixture = try await Fixture(), owner = try await fixture.owner()
        try await owner.prepareLumeProbeConfiguration()
        _ = try fixture.storage.environmentForLumeProbe()
        let target = suffix.isEmpty ? fixture.root : fixture.root.appending(path: suffix)
        if acl { try FixtureACL.install(.everyoneRead, at: target) }
        else { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        #expect(throws: StorageFailure.protectionDrift) { _ = try fixture.storage.environmentForLumeProbe() }
        #expect(throws: StorageFailure.protectionDrift) { _ = try fixture.storage.environmentForLumeProbe() }
        #expect(throws: StorageFailure.protectionDrift) { try StorageProtection.verify(target) }
        await owner.close()
    }

    @Test(arguments: ["", "vms", "state", "state/lume-xdg", "staging"])
    func backupPolicyIsRecheckedWithoutRepair(_ suffix: String) async throws {
        let fixture = try await Fixture(), owner = try await fixture.owner()
        try await owner.prepareLumeProbeConfiguration()
        let target = suffix.isEmpty ? fixture.root : fixture.root.appending(path: suffix)
        let expected = suffix == "staging"
        try RuntimeStorage.writeBackupExclusion(target, !expected)
        #expect(throws: StorageFailure.protectionDrift) { _ = try fixture.storage.environmentForLumeProbe() }
        #expect(try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == !expected)
        await owner.close()
    }

    @Test(arguments: ["mode", "acl", "backup"])
    func explicitConfigurationRepairKeepsContentsAndIdentity(_ drift: String) async throws {
        let fixture = try await Fixture(), owner = try await fixture.owner()
        try await owner.prepareLumeProbeConfiguration()
        let before = StateFileIdentity(try StorageProtection.structure(fixture.configuration))
        let saved = fixture.configuration.appending(path: "saved-config")
        try Data("keep me".utf8).write(to: saved)
        switch drift {
        case "acl": try FixtureACL.install(.everyoneRead, at: fixture.configuration)
        case "backup": try RuntimeStorage.writeBackupExclusion(fixture.configuration, true)
        default: try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.configuration.path)
        }
        #expect(throws: StorageFailure.protectionDrift) { _ = try fixture.storage.environmentForLumeProbe() }
        try await owner.prepareLumeProbeConfiguration()
        _ = try fixture.storage.environmentForLumeProbe()
        #expect(StateFileIdentity(try StorageProtection.structure(fixture.configuration)) == before)
        #expect(try Data(contentsOf: saved) == Data("keep me".utf8))
        await owner.close()
    }

    @Test(arguments: [false, true])
    func unsafeConfigurationIsRefusedWithoutChangingItsDestination(_ link: Bool) async throws {
        let fixture = try await Fixture(), owner = try await fixture.owner()
        let destination = fixture.base.appending(path: "outside")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let saved = destination.appending(path: "unpublished")
        try Data("keep me".utf8).write(to: saved)
        if link { try FileManager.default.createSymbolicLink(at: fixture.configuration, withDestinationURL: destination) }
        else { try Data("not a directory".utf8).write(to: fixture.configuration) }
        await #expect(throws: StorageFailure.unsafeStructure) { try await owner.prepareLumeProbeConfiguration() }
        #expect(throws: StorageFailure.unsafeStructure) { _ = try fixture.storage.environmentForLumeProbe() }
        #expect(try StorageProtection.structure(destination).st_mode & 0o7777 == 0o755)
        #expect(try Data(contentsOf: saved) == Data("keep me".utf8))
        if link { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.configuration.path) == destination.path) }
        else { #expect(try Data(contentsOf: fixture.configuration) == Data("not a directory".utf8)) }
        await owner.close()
    }

    @Test(arguments: ["vms", "staging"])
    func unsafeWritableParentRefusesBeforeRepairingConfiguration(_ suffix: String) async throws {
        let fixture = try await Fixture(), owner = try await fixture.owner()
        try await owner.prepareLumeProbeConfiguration()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.configuration.path)
        let target = fixture.root.appending(path: suffix)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        await #expect(throws: StorageFailure.protectionDrift) { try await owner.prepareLumeProbeConfiguration() }
        #expect(try StorageProtection.structure(fixture.configuration).st_mode & 0o7777 == 0o755)
        #expect(try StorageProtection.structure(target).st_mode & 0o7777 == 0o755)
        await owner.close()
    }

    @Test func losingAndClosedOwnersCannotPrepareConfiguration() async throws {
        let fixture = try await Fixture(), owner = try await fixture.owner()
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { _ = try await fixture.owner() }
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
        await owner.close()
        await #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) {
            try await owner.prepareLumeProbeConfiguration()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
    }

    @Test(arguments: [false, true])
    func preparationWaitsForLeaseAndRechecksOwnershipAfterWaiting(_ cancel: Bool) async throws {
        let fixture = try await Fixture(), owner = try await fixture.owner(), storage = fixture.storage
        let entered = AsyncStream.makeStream(of: Void.self), queued = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        var entryEvents = entered.stream.makeAsyncIterator(), queueEvents = queued.stream.makeAsyncIterator()
        let coordinator = LumeRuntimeCoordinator { queued.continuation.yield(()) }
        let holder = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                entered.continuation.yield(())
                var events = release.stream.makeAsyncIterator()
                _ = await events.next()
            }
        }
        _ = await entryEvents.next()
        let waiter = Task { try await owner.prepareLumeProbeConfiguration(coordinator: coordinator) }
        _ = await queueEvents.next()
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
        if cancel {
            waiter.cancel()
            await #expect(throws: CancellationError.self) { try await waiter.value }
        } else {
            await owner.close()
            // A queued request must not retain the closed owner's state-directory lock.
            let nextOwner = try await fixture.owner()
            release.continuation.yield(())
            await #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) { try await waiter.value }
            await nextOwner.close()
        }
        release.continuation.yield(())
        try await holder.value
        #expect(!FileManager.default.fileExists(atPath: fixture.configuration.path))
        await owner.close()
    }
}
