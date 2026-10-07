import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct LumeOwnedChildTests {
    private final class Fixture: Sendable {
        let base, root, record: URL
        init() throws {
            var template = Array("/private/tmp/guesthouse-lume-child-XXXXXX".utf8CString)
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
        func saved() throws -> LumeRuntimeOwnership {
            try JSONDecoder().decode(LumeRuntimeOwnership.self, from: Data(contentsOf: record))
        }
        func intent(_ owner: StateStore) async throws -> LumeLaunchIntent {
            try await owner.withLumeLaunchIntent(command: .version) { $0 }
        }
        func spawn(_ id: UUID, calls: OwnedChild.SystemCalls = .live) throws -> OwnedChild {
            let fd = open("/dev/null", O_RDWR | O_CLOEXEC)
            try #require(fd >= 0)
            defer { close(fd) }
            return try OwnedChild.spawn(runID: id, executable: URL(fileURLWithPath: "/usr/bin/true"),
                standardInput: fd, standardOutput: fd, standardError: fd, calls: calls)
        }
    }

    @Test func runnerAttachesActualIdentityAndExitNeverAuthorizesAnotherLaunch() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh()
        let argument = "temporary-argument-do-not-persist", environment = "temporary-environment-do-not-persist"
        let intent = try await fixture.intent(owner)
        var invocation = ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/printf"))
        invocation.arguments = ["%s", argument]; invocation.environment = ["FIXTURE": environment]
        let run = try await ProcessRunner().run(invocation, runID: intent.attemptID)
        try await owner.attachOwnedLumeChild(run.ownedChild, to: intent)
        let identity = try #require(try fixture.saved().child)
        #expect(identity.pid == run.ownedChild.processIdentifier)
        #expect(identity == run.ownedChild.launchIdentity)
        #expect(identity.runID == intent.attemptID)
        #expect(identity.startTime <= Date())
        #expect(identity.executablePath == invocation.executable.path)
        #expect(identity.argumentsDigest == LiveProcessProbe.digest(invocation.arguments))
        let report = try await run.waitForExit()
        #expect(report.childExit == .success(.status(0)))
        #expect(report.descendantScopeUnproven)
        let bytes = try Data(contentsOf: fixture.record)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(argument))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(environment))
        await owner.close()
        let restarted = try await fixture.reopen()
        #expect(try fixture.saved().child == identity)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(restarted) }
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await restarted.prepareLumeProbeConfiguration() }
        #expect(try Data(contentsOf: fixture.record) == bytes)
        await restarted.close()
    }

    @Test func foreignCorrelationAndRepeatedAttachmentPreserveTheFirstRecord() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let child = try fixture.spawn(intent.attemptID), wrongChild = try fixture.spawn(UUID())
        let before = try Data(contentsOf: fixture.record)
        let variants = [
            LumeLaunchIntent(operationID: UUID(), serviceEpoch: intent.serviceEpoch, attemptID: intent.attemptID, command: intent.command),
            LumeLaunchIntent(operationID: intent.operationID, serviceEpoch: UUID(), attemptID: intent.attemptID, command: intent.command),
            LumeLaunchIntent(operationID: intent.operationID, serviceEpoch: intent.serviceEpoch, attemptID: UUID(), command: intent.command),
            LumeLaunchIntent(operationID: intent.operationID, serviceEpoch: intent.serviceEpoch, attemptID: intent.attemptID, command: .createHelp)
        ]
        for variant in variants {
            await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
                try await owner.attachOwnedLumeChild(child, to: variant)
            }
            #expect(try Data(contentsOf: fixture.record) == before)
        }
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.attachOwnedLumeChild(wrongChild, to: intent)
        }
        #expect(try Data(contentsOf: fixture.record) == before)
        try await owner.attachOwnedLumeChild(child, to: intent)
        let attached = try Data(contentsOf: fixture.record), second = try fixture.spawn(intent.attemptID)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.attachOwnedLumeChild(second, to: intent)
        }
        #expect(try Data(contentsOf: fixture.record) == attached)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(await wrongChild.waitForReapedExit() == .success(.status(0)))
        #expect(await second.waitForReapedExit() == .success(.status(0)))
        await owner.close()
    }

    @Test func restartCannotAttachAPriorEpochEvenWithItsOriginalChild() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let child = try fixture.spawn(intent.attemptID), before = try Data(contentsOf: fixture.record)
        await owner.close()
        let restarted = try await fixture.reopen()
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await restarted.attachOwnedLumeChild(child, to: intent)
        }
        #expect(try Data(contentsOf: fixture.record) == before)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        await restarted.close()
    }

    @Test func unavailableBirthKeepsTheIntentUnknownAndTheChildReaped() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        var calls = OwnedChild.SystemCalls.live
        calls.birth = { _ in .unavailable }
        let child = try fixture.spawn(intent.attemptID, calls: calls), before = try Data(contentsOf: fixture.record)
        #expect(child.launchIdentity == nil)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.attachOwnedLumeChild(child, to: intent)
        }
        #expect(try Data(contentsOf: fixture.record) == before)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(owner) }
        await owner.close()
    }

    @Test(arguments: ["write", "file", "directory"])
    func failedAttachmentPreservesUnknownOwnershipAcrossRestart(_ stage: String) async throws {
        let fixture = try Fixture(), fresh = try await fixture.fresh()
        await fresh.close()
        let failing = Mutex(false)
        let owner = try await fixture.reopen(hooks: StateStoreHooks(ownershipWrite: { fd, bytes in
            if stage == "write", failing.withLock({ $0 }) { throw StateStoreError.fileUnwritable(name: .runtimeOwnership) }
            try StateFileIO.writeAll(fd, bytes, name: .runtimeOwnership)
        }, synchronize: { fd, name in
            if failing.withLock({ $0 }), (stage == "file" && name == .runtimeOwnership) || (stage == "directory" && name == .stateDirectory) {
                throw StateStoreError.fileUnwritable(name: name)
            }
            try StateFileIO.fullySynchronize(fd, name: name)
        }))
        let intent = try await fixture.intent(owner), child = try fixture.spawn(intent.attemptID)
        failing.withLock { $0 = true }
        await #expect(throws: (any Error).self) { try await owner.attachOwnedLumeChild(child, to: intent) }
        #expect(try fixture.saved().intent == intent)
        #expect((try fixture.saved().child != nil) == (stage == "directory"))
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            try await owner.attachOwnedLumeChild(child, to: intent)
        }
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        await owner.close()
        let restarted = try await fixture.reopen()
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(restarted) }
        await restarted.close()
    }

    @Test func canceledCallerStillRecordsTheChildThatAlreadyStarted() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let child = try fixture.spawn(intent.attemptID)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await owner.attachOwnedLumeChild(child, to: intent)
        }
        try await task.value
        #expect(try fixture.saved().child == child.launchIdentity)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        await owner.close()
    }

    @Test func fastExitedChildHasKernelBirthBeforeItsReaperStarts() async throws {
        let fixture = try Fixture()
        for _ in 0..<10 {
            let birth = Mutex<Date?>(nil)
            var calls = OwnedChild.SystemCalls.live
            calls.birth = { pid in
                // Force the native child to become waitable without reaping it. The ordinary
                // live probe still reports a zombie absent; only this spawn owner records it.
                guard case .success = OwnedChild.SystemCalls.live.waitForExit(pid) else { return .unavailable }
                #expect(LiveProcessProbe.Reads.readIdentity(pid) == .absent)
                let value = LiveProcessProbe.Reads.readOwnedChildIdentity(pid)
                if case .present(let time) = value { birth.withLock { $0 = time } }
                return value
            }
            let child = try fixture.spawn(UUID(), calls: calls)
            let identity = try #require(child.launchIdentity)
            #expect(identity.startTime == birth.withLock { $0 })
            #expect(identity.runID == child.runID)
            #expect(await child.waitForReapedExit() == .success(.status(0)))
            #expect(child.signal(SIGTERM) == .alreadyReaped)
        }
    }

    @Test(arguments: ["pid", "birth", "digest", "attempt", "missing-intent"])
    func malformedPersistedChildIsPreservedAndRefused(_ defect: String) async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let child = try fixture.spawn(intent.attemptID)
        try await owner.attachOwnedLumeChild(child, to: intent)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.record)) as? [String: Any])
        var identity = try #require(json["child"] as? [String: Any])
        switch defect {
        case "pid": identity["pid"] = 0
        case "birth": identity["startTime"] = -1_000_000_000_000
        case "digest": identity["argumentsDigest"] = "raw untrusted invocation"
        case "attempt": identity["runID"] = UUID().uuidString
        default: json.removeValue(forKey: "intent")
        }
        json["child"] = identity
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: fixture.record)
        await #expect(throws: LumeLaunchOwnershipFailure.corruptRecord) { _ = try await fixture.intent(owner) }
        #expect(try Data(contentsOf: fixture.record) == bytes)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        await owner.close()
    }
}
