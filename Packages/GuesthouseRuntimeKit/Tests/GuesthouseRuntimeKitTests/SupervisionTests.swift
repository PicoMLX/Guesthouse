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
        #expect(bySleepPath.processes.contains(live))
        let byPID = enumerator.candidates(executable: nil, pid: pid)
        #expect(byPID.processes == [live])
        #expect(enumerator.live(pid: 2_000_000_000) == nil)
    }

    @Test func recordedLaunchIsDurableAndReconcilesAsOwnedThenExited() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let supervisor = OperationSupervisor(store: store)
        let environment = EnvironmentID()
        // A stand-in for `tart run <vm>`: the trailing arguments are ignored by the program
        // but land in its argv, so the process names the VM the way a real launch does.
        // (A shell is unusable here: `/bin/sh` is reported as `/bin/bash` moments after it
        // starts, so its executable path is not stable.)
        let arguments = ["-e", "sleep 41", "run", environment.tartVMName]
        let fixture = URL(fileURLWithPath: "/usr/bin/perl")
        let run = try await ProcessRunner().run(ProcessInvocation(executable: fixture, arguments: arguments, timeout: .seconds(20)))
        let identity = try await supervisor.recordLaunch(pid: run.processIdentifier, executable: fixture, arguments: arguments, vmName: environment.tartVMName, environment: environment)
        let reloaded = try ProcessIdentityStore(directory: root)
        let persisted = try #require(await reloaded.identity(for: environment), "the file is on disk before recordLaunch returns")
        #expect(persisted.pid == identity.pid)
        #expect(persisted.executablePath == identity.executablePath)
        #expect(persisted.argumentsDigest == identity.argumentsDigest)
        #expect(persisted.vmName == identity.vmName)
        #expect(persisted.environmentID == identity.environmentID)
        #expect(persisted.startTime == identity.startTime, "the start time is an identity and survives the file exactly")
        #expect(persisted.recordedAt == identity.recordedAt)
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

    @Test func absentAndUnobservableProcessesAreDifferentAnswers() async throws {
        let enumerator = LiveProcessEnumerator()
        #expect(enumerator.observe(pid: 2_000_000_000) == .absent)
        #expect(enumerator.observe(pid: 0) == .absent)
        // launchd exists but its arguments are not readable by an ordinary user.
        guard case .unavailable = enumerator.observe(pid: 1) else { Issue.record("expected launchd to be unobservable"); return }
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["39"], timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        guard case .present(let live) = enumerator.observe(pid: run.processIdentifier) else { Issue.record("expected the spawned process"); return }
        #expect(live.claimedVMName == nil)
    }

    @Test func anUnobservableRecordedProcessIsUncertainNotExited() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let environment = EnvironmentID()
        try await store.record(ProcessIdentity(pid: 1, startTime: Date(timeIntervalSince1970: 0), executablePath: "/sbin/launchd", argumentsDigest: "sha256:0", vmName: environment.tartVMName, environmentID: environment, recordedAt: Date()))
        let verdicts = await OperationSupervisor(store: store).reconcile(environments: []) { _ in .absent }
        #expect(verdicts[environment] == .uncertain(.processUnobservable))
    }

    @Test func theClaimedVMNameIsTheFirstPositionalAfterRunAndMustBeAppManaged() {
        let name = EnvironmentID().tartVMName
        #expect(LiveProcessEnumerator.claimedVMName(in: ["run", name, "--no-graphics"]) == name)
        #expect(LiveProcessEnumerator.claimedVMName(in: ["run", "--no-graphics", name]) == name)
        #expect(LiveProcessEnumerator.claimedVMName(in: ["--vnc", name]) == nil)
        #expect(LiveProcessEnumerator.claimedVMName(in: ["run", "ubuntu"]) == nil)
        #expect(LiveProcessEnumerator.claimedVMName(in: ["run"]) == nil)
        #expect(LiveProcessEnumerator.claimedVMName(in: ["stop", name]) == nil)
    }

    @Test func anUnreadableRecordIsActionable() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Supervision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: ProcessIdentityStore.fileName))
        let error = #expect(throws: ProcessIdentityStoreError.self) { try ProcessIdentityStore(directory: directory) }
        guard case .unreadable(let path, _)? = error else { Issue.record("expected unreadable, got \(String(describing: error))"); return }
        #expect(path.hasSuffix(ProcessIdentityStore.fileName))
        #expect(error?.recoveryActions.first == .inspectState)
        #expect(error?.userMessage.contains("inspect") == true)
    }

    @Test func aRecordFiledUnderTheWrongEnvironmentIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let a = EnvironmentID(), b = EnvironmentID()
        let identity = ProcessIdentity(pid: 1, startTime: Date(), executablePath: "/x", argumentsDigest: "sha256:0", vmName: b.tartVMName, environmentID: b, recordedAt: Date())
        let document = ProcessIdentityStore.Document(identities: [a: identity])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(document).write(to: directory.appending(path: ProcessIdentityStore.fileName))
        let error = #expect(throws: ProcessIdentityStoreError.self) { try ProcessIdentityStore(directory: directory) }
        guard case .unreadable? = error else { Issue.record("expected unreadable, got \(String(describing: error))"); return }
    }

    @Test func aLinkedIdentityFileIsRefusedAndStaleTemporariesAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let elsewhere = directory.appending(path: "elsewhere.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: ProcessIdentityStore.fileName), withDestinationURL: elsewhere)
        #expect(throws: ProcessIdentityStoreError.self) { try ProcessIdentityStore(directory: directory) }
        try FileManager.default.removeItem(at: directory.appending(path: ProcessIdentityStore.fileName))
        let stale = directory.appending(path: ".\(ProcessIdentityStore.fileName).tmp-old")
        try Data("leftover".utf8).write(to: stale)
        _ = try ProcessIdentityStore(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: stale.path), "an interrupted write leaves nothing behind")
    }

    @Test func aLaunchMustNameTheVMItIsRecordedFor() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let supervisor = OperationSupervisor(store: store)
        let environment = EnvironmentID(), other = EnvironmentID()
        let arguments = ["-e", "sleep 41", "run", other.tartVMName]
        let fixture = URL(fileURLWithPath: "/usr/bin/perl")
        let run = try await ProcessRunner().run(ProcessInvocation(executable: fixture, arguments: arguments, timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        await #expect(throws: SupervisionError.processMismatch(pid: run.processIdentifier)) {
            _ = try await supervisor.recordLaunch(pid: run.processIdentifier, executable: fixture, arguments: arguments, vmName: environment.tartVMName, environment: environment)
        }
    }

    @Test func aClaimantWithoutARecordOrLockIsUncertain() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let environment = EnvironmentID()
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "sleep 41", "run", environment.tartVMName], timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        let verdicts = await OperationSupervisor(store: store).reconcile(environments: [environment]) { _ in .absent }
        #expect(verdicts[environment] == .uncertain(.anotherProcessClaimsVM), "a launch that has not taken the lock yet is not a free environment")
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
