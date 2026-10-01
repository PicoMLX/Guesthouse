import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct LumeLaunchIntentTests {
    private final class Fixture: Sendable {
        let base, root, record: URL
        init() throws {
            var template = Array("/private/tmp/guesthouse-lume-intent-XXXXXX".utf8CString)
            let name = try #require(mkdtemp(&template))
            base = URL(fileURLWithPath: String(cString: name))
            root = base.appending(path: "Guesthouse")
            record = root.appending(path: "state/lume-ownership.json")
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func fresh() async throws -> StateStore { try await StateStore.createFresh(root: { self.root }) }
        func reopen(hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(existingRoot: self.root) }, hooks: hooks)
        }
        func mode() throws -> mode_t {
            var info = stat()
            try #require(lstat(record.path, &info) == 0)
            return info.st_mode
        }
        func saved() throws -> LumeRuntimeOwnership {
            try JSONDecoder().decode(LumeRuntimeOwnership.self, from: Data(contentsOf: record))
        }
        func write(_ bytes: Data) throws {
            try bytes.write(to: record)
            try #require(chmod(record.path, 0o600) == 0)
        }
    }

    @Test func intentIsPublishedBeforeEnteringEffectsAndCompletionDoesNotSettleIt() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh()
        let initial = try fixture.saved()
        #expect(initial.intent == nil)
        #expect(initial.root == (try RuntimeStorage(existingRoot: fixture.root).coordinationIdentity()))
        let previous = open(fixture.record.path, O_RDONLY | O_CLOEXEC)
        try #require(previous >= 0)
        defer { close(previous) }
        let before = try Data(contentsOf: fixture.record)
        let intent = try await owner.withLumeLaunchIntent(command: .version) { intent in
            let recorded = try fixture.saved()
            #expect(recorded.intent == intent)
            #expect(intent.command == .version)
            #expect(intent.operationID != intent.attemptID)
            return intent
        }
        #expect(try StateFileIO.readAll(previous, from: 0, name: .runtimeOwnership) == before)
        #expect(try fixture.saved().intent == intent)
        #expect(try fixture.mode() & 0o7777 == 0o600)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.withLumeLaunchIntent(command: .createHelp) { _ in Issue.record("Repeated launch") }
        }
        await owner.close()
    }

    @Test(arguments: ["return", "throw", "cancel"])
    func unfinishedIntentSurvivesAllCallerExitsAndRestart(_ exit: String) async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh()
        do {
            try await owner.withLumeLaunchIntent(command: .detachedRunHelp) { _ in
                if exit == "throw" { throw LumeLaunchOwnershipFailure.inspectionRequired }
                if exit == "cancel" { throw CancellationError() }
            }
            #expect(exit == "return")
        } catch { #expect(exit != "return") }
        let bytes = try Data(contentsOf: fixture.record)
        await owner.close()
        let reopened = try await fixture.reopen()
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await reopened.withLumeLaunchIntent(command: .attachHelp) { _ in Issue.record("Replayed after restart") }
        }
        #expect(try Data(contentsOf: fixture.record) == bytes)
        await reopened.close()
    }

    @Test(arguments: ["missing", "corrupt", "future", "root", "oversize", "permissions"])
    func absentOrUnusableRecordsNeverAuthorizeLaunchOrRepair(_ defect: String) async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh()
        let saved = try fixture.saved()
        switch defect {
        case "missing": try FileManager.default.removeItem(at: fixture.record)
        case "corrupt": try fixture.write(Data("not a record".utf8))
        case "future":
            let raw = String(decoding: try Data(contentsOf: fixture.record), as: UTF8.self)
            try fixture.write(Data(raw.replacingOccurrences(of: "\"format\":1", with: "\"format\":99").utf8))
        case "root":
            let other = try Fixture(), otherOwner = try await other.fresh()
            try fixture.write(JSONEncoder().encode(try other.saved()))
            await otherOwner.close()
        case "oversize": try fixture.write(Data(repeating: 0, count: StateFileIO.maximumRuntimeOwnershipBytes + 1))
        default: try #require(chmod(fixture.record.path, 0o644) == 0)
        }
        let before = try? Data(contentsOf: fixture.record)
        await #expect(throws: (any Error).self) {
            try await owner.withLumeLaunchIntent(command: .version) { _ in Issue.record("Launched with unusable record") }
        }
        #expect((try? Data(contentsOf: fixture.record)) == before)
        if defect == "permissions" { #expect(try fixture.mode() & 0o7777 == 0o644) }
        if defect == "root" { #expect(try fixture.saved().root != saved.root) }
        await owner.close()
    }

    @Test func ordinaryOpenDoesNotEnrollAnExistingRootEvenWithEmptyInventory() async throws {
        let fixture = try Fixture()
        _ = try RuntimeStorage(root: fixture.root)
        let owner = try await fixture.reopen()
        #expect(try await owner.loadSnapshot().environments.isEmpty)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.withLumeLaunchIntent(command: .version) { _ in Issue.record("Inferred idle from missing file") }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.prepareLumeProbeConfiguration()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "state/lume-xdg").path))
        await owner.close()
    }

    @Test(arguments: ["write", "file", "directory", "temporary"])
    func failedPublicationNeverEntersEffectsAndBlocksTheLiveOwner(_ stage: String) async throws {
        let fixture = try Fixture(), fresh = try await fixture.fresh()
        await fresh.close()
        let hooks = StateStoreHooks(ownershipWrite: { fd, bytes in
            if stage == "write" {
                try StateFileIO.writeAll(fd, Data(bytes.prefix(8)), name: .runtimeOwnership)
                throw StateStoreError.fileUnwritable(name: .runtimeOwnership)
            }
            try StateFileIO.writeAll(fd, bytes, name: .runtimeOwnership)
        }, synchronize: { fd, name in
            if (stage == "file" && name == .runtimeOwnership) || (stage == "directory" && name == .stateDirectory) {
                throw StateStoreError.fileUnwritable(name: name)
            }
            try StateFileIO.fullySynchronize(fd, name: name)
        })
        let pending = fixture.root.appending(path: "state/.lume-ownership.json.pending")
        if stage == "temporary" { try Data("preserve evidence".utf8).write(to: pending) }
        let owner = try await fixture.reopen(hooks: hooks)
        await #expect(throws: (any Error).self) {
            try await owner.withLumeLaunchIntent(command: .version) { _ in Issue.record("Entered effects after write failure") }
        }
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.withLumeLaunchIntent(command: .version) { _ in Issue.record("Retried uncertain publication") }
        }
        if stage == "temporary" { #expect(try Data(contentsOf: pending) == Data("preserve evidence".utf8)) }
        if stage == "directory" { #expect(try fixture.saved().intent != nil) }
        else { #expect(try fixture.saved().intent == nil) }
        await owner.close()
        if stage == "directory" {
            let restarted = try await fixture.reopen()
            await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
                try await restarted.withLumeLaunchIntent(command: .version) { _ in Issue.record("Lost published intent") }
            }
            await restarted.close()
        }
    }

    @Test(arguments: [false, true])
    func queuedAdmissionRechecksClosedOwnershipAndCancellation(_ cancel: Bool) async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh()
        let storage = try RuntimeStorage(existingRoot: fixture.root)
        let entered = AsyncStream.makeStream(of: Void.self), queued = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        var entries = entered.stream.makeAsyncIterator(), queues = queued.stream.makeAsyncIterator()
        let coordinator = LumeRuntimeCoordinator { queued.continuation.yield(()) }
        let holder = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                entered.continuation.yield(())
                var events = release.stream.makeAsyncIterator(); _ = await events.next()
            }
        }
        _ = await entries.next()
        let waiter = Task {
            try await owner.withLumeLaunchIntent(command: .version, coordinator: coordinator) { _ in Issue.record("Entered refused effects") }
        }
        _ = await queues.next()
        if cancel {
            waiter.cancel()
            await #expect(throws: CancellationError.self) { try await waiter.value }
        } else {
            await owner.close()
            let nextOwner = try await fixture.reopen()
            release.continuation.yield(())
            await #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) { try await waiter.value }
            await nextOwner.close()
        }
        release.continuation.yield(())
        try await holder.value
        #expect(try fixture.saved().intent == nil)
        await owner.close()
    }

    @Test func concurrentAdmissionKeepsOneLiveOwnerAndOneIntent() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh()
        let entered = AsyncStream.makeStream(of: Void.self), queued = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        var entries = entered.stream.makeAsyncIterator(), queues = queued.stream.makeAsyncIterator()
        let coordinator = LumeRuntimeCoordinator { queued.continuation.yield(()) }
        let first = Task {
            try await owner.withLumeLaunchIntent(command: .version, coordinator: coordinator) { _ in
                entered.continuation.yield(())
                var events = release.stream.makeAsyncIterator(); _ = await events.next()
            }
        }
        _ = await entries.next()
        let before = try Data(contentsOf: fixture.record)
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { _ = try await fixture.reopen() }
        let second = Task {
            try await owner.withLumeLaunchIntent(command: .createHelp, coordinator: coordinator) { _ in Issue.record("Concurrent launch") }
        }
        _ = await queues.next()
        release.continuation.yield(())
        try await first.value
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await second.value }
        #expect(try Data(contentsOf: fixture.record) == before)
        await owner.close()
    }

    @Test(arguments: [false, true])
    func unknownLaunchBlocksConfigurationRepairAcrossRestart(_ restart: Bool) async throws {
        let fixture = try Fixture()
        var owner = try await fixture.fresh()
        try await owner.prepareLumeProbeConfiguration()
        try await owner.withLumeLaunchIntent(command: .version) { _ in }
        if restart { await owner.close(); owner = try await fixture.reopen() }
        let configuration = fixture.root.appending(path: "state/lume-xdg")
        try #require(chmod(configuration.path, 0o755) == 0)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.prepareLumeProbeConfiguration()
        }
        #expect(try StorageProtection.structure(configuration).st_mode & 0o7777 == 0o755)
        await owner.close()
    }

    @Test func cancellationDuringPublicationRetainsIntentWithoutEnteringEffects() async throws {
        let fixture = try Fixture(), fresh = try await fixture.fresh()
        await fresh.close()
        let owner = try await fixture.reopen(hooks: StateStoreHooks(ownershipWrite: { fd, bytes in
            try StateFileIO.writeAll(fd, bytes, name: .runtimeOwnership)
            withUnsafeCurrentTask { $0?.cancel() }
        }))
        let attempt = Task {
            try await owner.withLumeLaunchIntent(command: .version) { _ in Issue.record("Entered canceled effects") }
        }
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(try fixture.saved().intent != nil)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.withLumeLaunchIntent(command: .version) { _ in Issue.record("Repeated canceled intent") }
        }
        await owner.close()
    }
}
