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
        let owned = await supervisor.reconcile(environments: []) { _ in .present }
        guard case .ownedRunning(let live)? = owned[environment] else { Issue.record("expected owned, got \(String(describing: owned[environment]))"); return }
        #expect(live.pid == run.processIdentifier)

        run.terminate(gracePeriod: .milliseconds(100))
        _ = await run.exit()
        let gone = await supervisor.reconcile(environments: []) { _ in .absent }
        #expect(gone[environment] == .exited)
        let locked = await supervisor.reconcile(environments: []) { _ in .unknown }
        #expect(locked[environment] == .uncertain(.inventoryUnavailable), "unknown lock state errs toward uncertainty")
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
        let verdicts = await supervisor.reconcile(environments: []) { _ in .absent }
        #expect(verdicts[environment] == .uncertain(.pidReusedByAnotherProcess))
    }

    @Test func aMismatchedObservationIsNeverRecorded() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Supervision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ProcessIdentityStore(directory: directory)
        let supervisor = OperationSupervisor(store: store)
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .seconds(10)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        await #expect(throws: SupervisionError.processMismatch(pid: run.processIdentifier)) {
            try await supervisor.recordLaunch(pid: run.processIdentifier, executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["6"], vmName: "vm", environment: EnvironmentID())
        }
        await #expect(throws: SupervisionError.processMismatch(pid: run.processIdentifier)) {
            try await supervisor.recordLaunch(pid: run.processIdentifier, executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["5"], vmName: "vm", environment: EnvironmentID())
        }
        #expect(await store.all.isEmpty)
        for error in [SupervisionError.processNotObservable(pid: 1), .processMismatch(pid: 1)] {
            #expect(!error.userMessage.isEmpty && error.recoveryActions.first == .inspectState)
        }
    }

    @Test func unrecordedAndUnknownInventoriesAreUncertain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Supervision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let supervisor = OperationSupervisor(store: try ProcessIdentityStore(directory: directory))
        let locked = EnvironmentID(), free = EnvironmentID(), unknown = EnvironmentID()
        let verdicts = await supervisor.reconcile(environments: [locked, free, unknown]) { id in
            id == locked ? .present : id == free ? .absent : .unknown
        }
        #expect(verdicts[locked] == .uncertain(.unrecordedLaunch))
        #expect(verdicts[free] == nil)
        #expect(verdicts[unknown] == .uncertain(.inventoryUnavailable))
    }

    @Test func aFailedPersistLeavesMemoryUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Supervision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ProcessIdentityStore(directory: directory)
        let identity = ProcessIdentity(pid: 1, startTime: Date(), executablePath: "/x", argumentsDigest: "d", vmName: "vm", environmentID: EnvironmentID(), recordedAt: Date())
        try await store.record(identity)
        try FileManager.default.removeItem(at: directory)
        let other = ProcessIdentity(pid: 2, startTime: Date(), executablePath: "/y", argumentsDigest: "e", vmName: "vm2", environmentID: EnvironmentID(), recordedAt: Date())
        await #expect(throws: ProcessIdentityStoreError.self) { try await store.record(other) }
        #expect(await store.all.count == 1)
        await #expect(throws: ProcessIdentityStoreError.self) { try await store.remove(identity.environmentID) }
        #expect(await store.all.count == 1)
        let error = ProcessIdentityStoreError.unwritable(path: "/x", reason: "ENOSPC")
        #expect(error.recoveryActions.first == .inspectState && !error.userMessage.isEmpty)
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
