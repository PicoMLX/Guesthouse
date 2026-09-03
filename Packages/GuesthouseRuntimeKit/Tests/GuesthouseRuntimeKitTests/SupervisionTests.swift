import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.serialized) struct SupervisionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "SupervisionTests-\(UUID().uuidString)")

    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    @Test func enumeratorObservesASpawnedProcessExactly() async throws {
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["37"], timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        let pid = run.processIdentifier
        let enumerator = LiveProcessEnumerator()
        let live = try #require(enumerator.live(pid: pid))
        #expect(live.pid == pid)
        #expect(live.executablePath == "/bin/sleep")
        #expect(abs(live.startTime.timeIntervalSinceNow) < 30)
        #expect(live.argumentsDigest == LiveProcessEnumerator.digest(of: ["37"]))
        #expect(live.argumentsDigest != LiveProcessEnumerator.digest(of: ["38"]))
        let bySleepPath = enumerator.candidates(executable: URL(fileURLWithPath: "/bin/sleep"), pid: nil)
        #expect(bySleepPath.contains(live))
        let byPID = enumerator.candidates(executable: nil, pid: pid)
        #expect(byPID == [live])
        #expect(enumerator.live(pid: 2_000_000_000) == nil)
    }

    @Test func recordedLaunchIsDurableAndReconcilesAsOwnedThenExited() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let supervisor = OperationSupervisor(store: store)
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["41"], timeout: .seconds(20)))
        let environment = EnvironmentID()
        let identity = try await supervisor.recordLaunch(pid: run.processIdentifier, executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["41"], vmName: environment.tartVMName, environment: environment)
        let reloaded = try ProcessIdentityStore(directory: root)
        let persisted = try #require(await reloaded.identity(for: environment), "the file is on disk before recordLaunch returns")
        #expect(persisted.pid == identity.pid)
        #expect(persisted.executablePath == identity.executablePath)
        #expect(persisted.argumentsDigest == identity.argumentsDigest)
        #expect(persisted.vmName == identity.vmName)
        #expect(persisted.environmentID == identity.environmentID)
        #expect(abs(persisted.startTime.timeIntervalSince(identity.startTime)) < 0.001, "millisecond precision survives the file")
        // Recorded dates are rounded to milliseconds when persisted; the difference is at most one.
        #expect(abs(persisted.recordedAt.timeIntervalSince(identity.recordedAt)) <= 0.0015)
        let owned = await supervisor.reconcile { _ in true }
        guard case .ownedRunning(let live)? = owned[environment] else { Issue.record("expected owned, got \(String(describing: owned[environment]))"); return }
        #expect(live.pid == run.processIdentifier)

        run.terminate(gracePeriod: .milliseconds(100))
        _ = await run.exit()
        let gone = await supervisor.reconcile { _ in false }
        #expect(gone[environment] == .exited)
        let locked = await supervisor.reconcile { _ in nil }
        #expect(locked[environment] == .uncertain(.lockHeldWithoutProcess), "unknown lock state errs toward uncertainty")
        try await supervisor.forget(environment)
        #expect(await store.all.isEmpty)
    }

    @Test func aReusedPIDIsNeverMistakenForTheRecordedProcess() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let supervisor = OperationSupervisor(store: store)
        let first = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["43"], timeout: .seconds(20)))
        defer { first.terminate(gracePeriod: .milliseconds(100)) }
        let live = try #require(LiveProcessEnumerator().live(pid: first.processIdentifier))
        let environment = EnvironmentID()
        let stale = ProcessIdentity(pid: live.pid, startTime: live.startTime.addingTimeInterval(-3600), executablePath: live.executablePath, argumentsDigest: live.argumentsDigest, vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        try await store.record(stale)
        let verdicts = await supervisor.reconcile { _ in false }
        #expect(verdicts[environment] == .uncertain(.pidReusedByAnotherProcess))
    }

    @Test func transactionsAreCountedAndEndedOnce() {
        let supervisor = OperationSupervisor(store: try! ProcessIdentityStore(directory: root))
        #expect(supervisor.outstandingTransactions == 0)
        let a = supervisor.hold("operation")
        let b = supervisor.hold("vm")
        #expect(supervisor.outstandingTransactions == 2)
        a.end(); a.end()
        #expect(supervisor.outstandingTransactions == 1)
        b.end()
        #expect(supervisor.outstandingTransactions == 0)
    }

    @Test func identityStoreWritesRestrictedFilesAtomically() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let environment = EnvironmentID()
        try await store.record(ProcessIdentity(pid: 1, startTime: Date(timeIntervalSince1970: 1_800_000_000.25), executablePath: "/x", argumentsDigest: "sha256:0", vmName: environment.tartVMName, environmentID: environment, recordedAt: Date(timeIntervalSince1970: 1_800_000_001)))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".processes.json.tmp-") }.isEmpty)
        let reloaded = try ProcessIdentityStore(directory: root)
        #expect(await reloaded.identity(for: environment)?.startTime == Date(timeIntervalSince1970: 1_800_000_000.25))
    }
}
