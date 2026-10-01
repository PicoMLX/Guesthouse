import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct LumeLaunchSettlementTests {
    private final class Fixture: Sendable {
        let base, root, record: URL
        init() throws {
            var template = Array("/private/tmp/guesthouse-lume-settlement-XXXXXX".utf8CString)
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
        func spawn(_ intent: LumeLaunchIntent, observing: Bool = true,
                   executable: URL = URL(fileURLWithPath: "/usr/bin/true"), input: Int32? = nil) throws -> OwnedChild {
            let fd = open("/dev/null", O_RDWR | O_CLOEXEC)
            try #require(fd >= 0)
            defer { close(fd) }
            return try OwnedChild.spawn(runID: intent.attemptID, observingForks: observing, executable: executable,
                standardInput: input ?? fd, standardOutput: fd, standardError: fd)
        }
    }

    @Test func actualNoForkInspectionSettlesExplicitlyAndPreservesWork() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let work = fixture.root.appending(path: "vms/preserved-work")
        try Data([1, 2, 3]).write(to: work)
        let root = try fixture.saved().root
        let child = try fixture.spawn(intent)
        try await owner.attachOwnedLumeChild(child, to: intent)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        let pending = try Data(contentsOf: fixture.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(owner) }
        #expect(try Data(contentsOf: fixture.record) == pending)
        try await owner.settleInspectedLumeLaunch(intent)
        #expect(try fixture.saved() == LumeRuntimeOwnership(root: root))
        #expect(try Data(contentsOf: work) == Data([1, 2, 3]))
        let next = try await fixture.intent(owner)
        #expect(next.attemptID != intent.attemptID)
        #expect(next.serviceEpoch == intent.serviceEpoch)
        // An old success cannot settle the next attempt, and no automatic replay is scheduled.
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(intent) }
        #expect(try fixture.saved().intent == next)
        await owner.close()
    }

    @Test func missingAttachmentAndOrdinaryExitAreNotInspectionProof() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let observed = try fixture.spawn(intent)
        #expect(await observed.waitForReapedExit() == .success(.status(0)))
        let before = try Data(contentsOf: fixture.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(intent) }
        #expect(try Data(contentsOf: fixture.record) == before)
        let ordinary = try fixture.spawn(intent, observing: false)
        try await owner.attachOwnedLumeChild(ordinary, to: intent)
        #expect(await ordinary.waitForReapedExit() == .success(.status(0)))
        let attached = try Data(contentsOf: fixture.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(intent) }
        #expect(try Data(contentsOf: fixture.record) == attached)
        await owner.close()
    }

    @Test(arguments: [false, true])
    func anActualForkRemainsBlockedAfterBothProcessesExit(throughRunner: Bool) async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let source = fixture.base.appending(path: "fork.c"), executable = fixture.base.appending(path: "fork")
        try Data("""
        #include <unistd.h>
        #include <sys/wait.h>
        int main(void) { pid_t pid = fork(); if (pid < 0) return 1;
            if (!pid) _exit(0); int status; return waitpid(pid, &status, 0) == pid ? 0 : 2; }
        """.utf8).write(to: source)
        var invocation = ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/clang"))
        invocation.arguments = ["-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path]
        invocation.timeout = .seconds(20)
        let run = try await ProcessRunner().run(invocation)
        try #require(await run.waitForExit().childExit == .success(.status(0)))
        let child: OwnedChild
        if throughRunner {
            var invocation = ProcessInvocation(executable: executable)
            invocation.observation = .forkHistory
            let run = try await ProcessRunner().run(invocation, runID: intent.attemptID)
            child = run.ownedChild
            let report = try await run.waitForExit()
            #expect(report.childExit == .success(.status(0)) && report.descendantScopeUnproven)
        } else { child = try fixture.spawn(intent, executable: executable) }
        try await owner.attachOwnedLumeChild(child, to: intent)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(child.forkObservation == .forkObserved)
        let before = try Data(contentsOf: fixture.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(intent) }
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(owner) }
        #expect(try Data(contentsOf: fixture.record) == before)
        await owner.close()
    }

    @Test(arguments: [false, true])
    func runnerReturnRetainsIntentUntilExplicitActualInspection(observing: Bool) async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh()
        let (intent, run) = try await owner.withLumeLaunchIntent(command: .version) { intent in
            var invocation = ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/true"))
            invocation.observation = observing ? .forkHistory : .ordinary
            let run = try await ProcessRunner().run(invocation, runID: intent.attemptID)
            try await owner.attachOwnedLumeChild(run.ownedChild, to: intent)
            return (intent, run)
        }
        #expect(try await run.waitForExit().childExit?.get() == .status(0))
        let pending = try Data(contentsOf: fixture.record)
        #expect(try fixture.saved().child == run.ownedChild.launchIdentity)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(owner) }
        #expect(try Data(contentsOf: fixture.record) == pending)
        if observing {
            try await owner.settleInspectedLumeLaunch(intent)
            #expect(try fixture.saved().intent == nil)
            #expect(try await fixture.intent(owner).attemptID != intent.attemptID)
        } else {
            await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(intent) }
            #expect(try Data(contentsOf: fixture.record) == pending)
        }
        await owner.close()
    }

    @Test(arguments: [false, true])
    func runnerInterruptionNeedsActualInspectionBeforeReplacement(timeout: Bool) async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh()
        let (intent, run) = try await owner.withLumeLaunchIntent(command: .version) { intent in
            var invocation = ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
            invocation.observation = .forkHistory
            invocation.timeout = timeout ? .milliseconds(100) : .seconds(30)
            invocation.terminationGracePeriod = .zero
            let run = try await ProcessRunner().run(invocation, runID: intent.attemptID)
            try await owner.attachOwnedLumeChild(run.ownedChild, to: intent)
            return (intent, run)
        }
        let pending = try Data(contentsOf: fixture.record)
        if !timeout { await run.terminate(gracePeriod: .zero) }
        let report = try await run.waitForExit()
        #expect(report.timedOut == timeout && report.canceled != timeout)
        #expect(report.childExit != nil && report.descendantScopeUnproven)
        #expect(run.ownedChild.forkObservation == .exitedWithoutFork)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(owner) }
        #expect(try Data(contentsOf: fixture.record) == pending)
        // The interruption/report changes no metadata. Separate actual live-owner
        // inspection may clear only this completed no-fork attempt, not its outcome.
        try await owner.settleInspectedLumeLaunch(intent)
        #expect(try fixture.saved().intent == nil)
        await owner.close()
    }

    @Test func runningChildKeepsItsIntentUntilActualInspection() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner), input = Pipe()
        let child = try fixture.spawn(intent, executable: URL(fileURLWithPath: "/bin/cat"), input: input.fileHandleForReading.fileDescriptor)
        try input.fileHandleForReading.close()
        defer { try? input.fileHandleForWriting.close() }
        try await owner.attachOwnedLumeChild(child, to: intent)
        let before = try Data(contentsOf: fixture.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(intent) }
        #expect(try Data(contentsOf: fixture.record) == before)
        try input.fileHandleForWriting.close()
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        try await owner.settleInspectedLumeLaunch(intent)
        await owner.close()
    }

    @Test func restartAndForeignCorrelationNeverBorrowSavedProof() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let child = try fixture.spawn(intent)
        try await owner.attachOwnedLumeChild(child, to: intent)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        let before = try Data(contentsOf: fixture.record)
        let foreign = LumeLaunchIntent(operationID: UUID(), serviceEpoch: intent.serviceEpoch,
            attemptID: intent.attemptID, command: intent.command)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(foreign) }
        #expect(try Data(contentsOf: fixture.record) == before)
        await owner.close()
        let restarted = try await fixture.reopen()
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await restarted.settleInspectedLumeLaunch(intent) }
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(restarted) }
        #expect(try Data(contentsOf: fixture.record) == before)
        await restarted.close()
    }

    @Test(arguments: ["write", "file", "directory"])
    func failedSettlementNeverReleasesTheCurrentOwner(_ stage: String) async throws {
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
        let intent = try await fixture.intent(owner), child = try fixture.spawn(intent)
        try await owner.attachOwnedLumeChild(child, to: intent)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        failing.withLock { $0 = true }
        await #expect(throws: (any Error).self) { try await owner.settleInspectedLumeLaunch(intent) }
        #expect((try fixture.saved().intent == nil) == (stage == "directory"))
        failing.withLock { $0 = false }
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(intent) }
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await fixture.intent(owner) }
        await owner.close()
    }

    @Test func canceledSettlementPreservesPendingInspection() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let child = try fixture.spawn(intent)
        try await owner.attachOwnedLumeChild(child, to: intent)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        let before = try Data(contentsOf: fixture.record)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await owner.settleInspectedLumeLaunch(intent)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: fixture.record) == before)
        try await owner.settleInspectedLumeLaunch(intent)
        await owner.close()
    }

    @Test func aSavedReceiptCannotReplaceTheActuallyRetainedChild() async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let child = try fixture.spawn(intent)
        try await owner.attachOwnedLumeChild(child, to: intent)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        let foreign = try fixture.spawn(intent)
        #expect(await foreign.waitForReapedExit() == .success(.status(0)))
        let saved = try fixture.saved()
        let bytes = try JSONEncoder().encode(LumeRuntimeOwnership(root: saved.root, intent: intent, child: foreign.launchIdentity))
        try bytes.write(to: fixture.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { try await owner.settleInspectedLumeLaunch(intent) }
        #expect(try Data(contentsOf: fixture.record) == bytes)
        await owner.close()
    }

    @Test(arguments: [false, true])
    func queuedInspectionRechecksLifetimeAndRoot(replaceRoot: Bool) async throws {
        let fixture = try Fixture(), owner = try await fixture.fresh(), intent = try await fixture.intent(owner)
        let child = try fixture.spawn(intent)
        try await owner.attachOwnedLumeChild(child, to: intent)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        let before = try Data(contentsOf: fixture.record)
        let storage = try RuntimeStorage(existingRoot: fixture.root)
        let (entered, signal) = AsyncStream<Void>.makeStream(), (queued, queue) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); queue.finish(); resume.finish() }
        let coordinator = LumeRuntimeCoordinator { queue.yield(()) }
        let holder = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                signal.yield(())
                for await _ in release { break }
            }
        }
        var arrivals = entered.makeAsyncIterator(), waits = queued.makeAsyncIterator()
        _ = await arrivals.next()
        let settling = Task { try await owner.settleInspectedLumeLaunch(intent, coordinator: coordinator) }
        _ = await waits.next()
        let moved = fixture.base.appending(path: "retained")
        if replaceRoot {
            try FileManager.default.moveItem(at: fixture.root, to: moved)
            _ = try RuntimeStorage(root: fixture.root)
        } else { await owner.close() }
        resume.yield(())
        try await holder.value
        await #expect(throws: (any Error).self) { try await settling.value }
        if replaceRoot {
            #expect(try Data(contentsOf: moved.appending(path: "state/lume-ownership.json")) == before)
            #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
            await owner.close()
        } else { #expect(try Data(contentsOf: fixture.record) == before) }
    }
}
