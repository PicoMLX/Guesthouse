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

    @Test func anUnreadableProcessIsNeverReportedAsExited() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let supervisor = OperationSupervisor(store: store)
        let environment = EnvironmentID()
        let arguments = ["-e", "sleep 47", "run", environment.tartVMName]
        let fixture = URL(fileURLWithPath: "/usr/bin/perl")
        let run = try await ProcessRunner().run(ProcessInvocation(executable: fixture, arguments: arguments, timeout: .seconds(20)))
        let live = try #require(LiveProcessEnumerator().live(pid: run.processIdentifier))
        let identity = ProcessIdentity(pid: live.pid, startTime: live.startTime, executablePath: live.executablePath, argumentsDigest: live.argumentsDigest, vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        #expect(supervisor.observe(identity) == .present(live))

        // A process this user owns whose arguments the kernel declines to describe: the one
        // shape that is genuinely unobservable. PID 1 is not it — launchd belongs to root, so
        // the recorded process it once was is certainly gone.
        let blind = LiveProcessEnumerator(kernel: .init(pids: { LiveProcessEnumerator.listAllPIDs() }, arguments: { _ in nil }))
        guard case .unavailable = blind.observe(pid: run.processIdentifier) else {
            Issue.record("an owned process with unreadable arguments must be unobservable")
            return
        }
        #expect(LiveProcessEnumerator().observe(pid: 1) == .absent, "another account's process is not the one we recorded")
        let unreadable = ProcessIdentity(pid: run.processIdentifier, startTime: identity.startTime, executablePath: live.executablePath, argumentsDigest: identity.argumentsDigest, vmName: identity.vmName, environmentID: environment, recordedAt: Date())
        let blindSupervisor = OperationSupervisor(store: store, enumerator: blind)
        #expect(blindSupervisor.observe(unreadable) == .unavailable)
        #expect(blindSupervisor.verify(unreadable) == nil, "unreadable is still not verified")

        run.terminate(gracePeriod: .milliseconds(100))
        _ = await run.exit()
        #expect(supervisor.observe(identity) == .absent, "a process that ended is definitely gone")
        let neverExisted = ProcessIdentity(pid: 2_000_000_000, startTime: identity.startTime, executablePath: identity.executablePath, argumentsDigest: identity.argumentsDigest, vmName: identity.vmName, environmentID: environment, recordedAt: Date())
        #expect(supervisor.observe(neverExisted) == .absent)
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
        let first = EnvironmentID(), second = EnvironmentID()
        let identity = ProcessIdentity(pid: 1, startTime: Date(), executablePath: "/x", argumentsDigest: "d", vmName: first.tartVMName, environmentID: first, recordedAt: Date())
        try await store.record(identity)
        try FileManager.default.removeItem(at: directory)
        let other = ProcessIdentity(pid: 2, startTime: Date(), executablePath: "/y", argumentsDigest: "e", vmName: second.tartVMName, environmentID: second, recordedAt: Date())
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
        // launchd exists, but it belongs to root: whatever was recorded under that PID is gone.
        #expect(enumerator.observe(pid: 1) == .absent)
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["39"], timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        guard case .present(let live) = enumerator.observe(pid: run.processIdentifier) else { Issue.record("expected the spawned process"); return }
        #expect(live.claimedVMName == nil)
    }

    @Test func anUnobservableRecordedProcessIsUncertainNotExited() async throws {
        let store = try ProcessIdentityStore(directory: root)
        let environment = EnvironmentID()
        // A live process of this user's whose arguments the kernel will not describe: the
        // reconciler must not read that refusal as an exit.
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["37"], timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        let blind = LiveProcessEnumerator(kernel: .init(pids: { LiveProcessEnumerator.listAllPIDs() }, arguments: { _ in nil }))
        try await store.record(ProcessIdentity(pid: run.processIdentifier, startTime: Date(timeIntervalSince1970: 0), executablePath: "/bin/sleep", argumentsDigest: "sha256:0", vmName: environment.tartVMName, environmentID: environment, recordedAt: Date()))
        let verdicts = await OperationSupervisor(store: store, enumerator: blind).reconcile(environments: []) { _ in .absent }
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

    @Test func aVMNameThatIsNotTheEnvironmentsIsRefused() async throws {
        // Arguments and vmName agree on VM B while the environment is A: recording that would
        // file a self-contradicting identity, which makes the whole document unreadable on
        // the next start.
        let store = try ProcessIdentityStore(directory: root)
        let supervisor = OperationSupervisor(store: store)
        let environment = EnvironmentID(), other = EnvironmentID()
        let arguments = ["-e", "sleep 41", "run", other.tartVMName]
        let fixture = URL(fileURLWithPath: "/usr/bin/perl")
        let run = try await ProcessRunner().run(ProcessInvocation(executable: fixture, arguments: arguments, timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        await #expect(throws: SupervisionError.processMismatch(pid: run.processIdentifier)) {
            _ = try await supervisor.recordLaunch(pid: run.processIdentifier, executable: fixture, arguments: arguments, vmName: other.tartVMName, environment: environment)
        }
        #expect(await store.identity(for: environment) == nil, "nothing was recorded")
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

    /// A fixture folder is created `0700` explicitly: continuous integration runs with a
    /// permissive umask, and the storage code refuses a folder other users can change.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func writeDocument(_ identities: [EnvironmentID: ProcessIdentity], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(ProcessIdentityStore.Document(identities: identities)).write(to: url)
    }

    @Test func aTartAtAnotherPathClaimingTheVMIsNotAnExit() async throws {
        let store = try ProcessIdentityStore(directory: try makeDirectory())
        let supervisor = OperationSupervisor(store: store)
        let environment = EnvironmentID()
        // A claimant started from a Tart at a path the record does not name, which is what a
        // runtime upgrade leaves behind.
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "sleep 43", "run", environment.tartVMName], timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        let recorded = ProcessIdentity(pid: 2_000_000_000, startTime: Date(), executablePath: "/opt/guesthouse/older/tart", argumentsDigest: "sha256:0", vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        try await store.record(recorded)
        let verdicts = await supervisor.reconcile(environments: []) { _ in .absent }
        #expect(verdicts[environment] == .uncertain(.anotherProcessClaimsVM), "a claimant at another executable path still holds the VM")
    }

    /// A VM lock says the VM is held, never by whom. While a second process names the same VM,
    /// an exact match on the record is not enough to call the environment ours.
    @Test func aCrossPathClaimantMakesAMatchingRecordUncertain() async throws {
        let environment = EnvironmentID()
        let owner = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "sleep 44"], timeout: .seconds(20)))
        defer { owner.terminate(gracePeriod: .milliseconds(100)) }
        let rival = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["44"], timeout: .seconds(20)))
        defer { rival.terminate(gracePeriod: .milliseconds(100)) }
        // Both name the VM; only their executables differ, which is what a runtime upgrade
        // leaves behind. Only the recorded one is found by the scan for the recorded binary.
        let arguments = ["run", environment.tartVMName]
        let enumerator = LiveProcessEnumerator(kernel: .init(
            pids: { [owner.processIdentifier, rival.processIdentifier] },
            arguments: { _ in arguments }
        ))
        let live = try #require(enumerator.live(pid: owner.processIdentifier))
        let store = try ProcessIdentityStore(directory: try makeDirectory())
        try await store.record(ProcessIdentity(pid: live.pid, startTime: live.startTime, executablePath: live.executablePath, argumentsDigest: LiveProcessEnumerator.digest(of: arguments), vmName: environment.tartVMName, environmentID: environment, recordedAt: Date()))
        let supervisor = OperationSupervisor(store: store, enumerator: enumerator)
        let verdicts = await supervisor.reconcile(environments: []) { _ in .present }
        #expect(verdicts[environment] == .uncertain(.anotherProcessClaimsVM), "the record matched, but so does somebody else's claim on the VM")
        // An inventory that could not be read is a reason to ask the process table harder, not
        // to hand the environment to the recorded process unchecked.
        let withoutInventory = await supervisor.reconcile(environments: []) { _ in .unknown }
        #expect(withoutInventory[environment] == .uncertain(.anotherProcessClaimsVM), "a rival claimant counts whether or not the inventory answered")
    }

    @Test func aProcessTableTheKernelWillNotListIsNotAnEmptyOne() async throws {
        let refusing = LiveProcessEnumerator(kernel: .init(pids: { nil }, arguments: { _ in nil }))
        #expect(refusing.candidates(executable: URL(fileURLWithPath: "/bin/sleep"), pid: nil).unreadable)
        #expect(refusing.claimants(ofVM: EnvironmentID().tartVMName).unreadable)
        let environment = EnvironmentID()
        let supervisor = OperationSupervisor(store: try ProcessIdentityStore(directory: try makeDirectory()), enumerator: refusing)
        let verdicts = await supervisor.reconcile(environments: [environment]) { _ in .absent }
        #expect(verdicts[environment] == .uncertain(.processUnobservable), "a scan that never happened never frees an environment")
    }

    @Test func onlyThisUsersRunningProcessesMakeAnUnreadableScanUncertain() async throws {
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["45"], timeout: .seconds(20)))
        defer { run.terminate(gracePeriod: .milliseconds(100)) }
        let vmName = EnvironmentID().tartVMName
        let mine = LiveProcessEnumerator(kernel: .init(pids: { [run.processIdentifier] }, arguments: { _ in nil }))
        #expect(mine.claimants(ofVM: vmName).unreadable, "a running process of ours whose arguments cannot be read may be the claimant")
        // PID 1 is launchd: another user's process, whose arguments no ordinary user can read.
        // Treating that everyday refusal as uncertainty would make every environment unusable.
        let launchd = LiveProcessEnumerator(kernel: .init(pids: { [1] }, arguments: { _ in nil }))
        #expect(!launchd.claimants(ofVM: vmName).unreadable)
        #expect(LiveProcessEnumerator().ownership(of: 1) == .notOurs)
        #expect(LiveProcessEnumerator().ownership(of: run.processIdentifier) == .own)
        // A child that exited but has not been reaped is still listed and its arguments are
        // gone; it holds nothing, so it must not make a scan uncertain either.
        var zombie: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { for argument in argv { free(argument) } }
        // An explicitly empty environment, never `environ`: nothing this process was launched
        // with — a developer's shell or a continuous-integration runner's credentials — belongs
        // in a child, in a fixture no less than in the product.
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        #expect(posix_spawn(&zombie, "/usr/bin/true", nil, nil, &argv, &environment) == 0)
        for _ in 0..<100 where LiveProcessEnumerator().ownership(of: zombie) == .own {
            try await Task.sleep(for: .milliseconds(20))
        }
        let reaped = zombie
        #expect(LiveProcessEnumerator().ownership(of: reaped) == .notOurs)
        #expect(!LiveProcessEnumerator(kernel: .init(pids: { [reaped] }, arguments: { _ in nil })).claimants(ofVM: vmName).unreadable)
        // A PID that is simply gone is an answer, not a refusal: absence has to stay absence,
        // or every scan would end uncertain.
        #expect(LiveProcessEnumerator().ownership(of: 0x7FFF_FFFE) == .notOurs)
    }

    @Test func anIdentityNamingAnotherVMIsNeverWritten() async throws {
        let directory = try makeDirectory()
        let store = try ProcessIdentityStore(directory: directory)
        let environment = EnvironmentID(), other = EnvironmentID()
        let inconsistent = ProcessIdentity(pid: 1, startTime: Date(), executablePath: "/x", argumentsDigest: "sha256:0", vmName: other.tartVMName, environmentID: environment, recordedAt: Date())
        let error = await #expect(throws: ProcessIdentityStoreError.self) { try await store.record(inconsistent) }
        guard case .inconsistentIdentity? = error else { Issue.record("expected inconsistentIdentity, got \(String(describing: error))"); return }
        #expect(error?.recoveryActions.first == .inspectState && error?.userMessage.isEmpty == false)
        #expect(await store.all.isEmpty)
        // The document a later start reads is still the one this store wrote, not a record
        // that would make every surviving VM unrecoverable.
        _ = try ProcessIdentityStore(directory: directory)
    }

    @Test func aPlantedIdentityFileIsRefusedInsteadOfTrustedOrWaitedOn() async throws {
        let dangling = try makeDirectory()
        try FileManager.default.createSymbolicLink(atPath: dangling.appending(path: ProcessIdentityStore.fileName).path, withDestinationPath: dangling.appending(path: "gone.json").path)
        #expect(throws: ProcessIdentityStoreError.self, "a link with no target is damaged evidence, not a first run") {
            try ProcessIdentityStore(directory: dangling)
        }

        let pipe = try makeDirectory()
        #expect(mkfifo(pipe.appending(path: ProcessIdentityStore.fileName).path, 0o600) == 0)
        let opened = #expect(throws: ProcessIdentityStoreError.self, "a named pipe is refused rather than waited on") {
            try ProcessIdentityStore(directory: pipe)
        }
        guard case .unreadable(_, let reason)? = opened else { Issue.record("expected unreadable, got \(String(describing: opened))"); return }
        #expect(reason.contains("not a regular file"))

        let linked = try makeDirectory()
        try writeDocument([:], to: linked.appending(path: ProcessIdentityStore.fileName))
        #expect(link(linked.appending(path: ProcessIdentityStore.fileName).path, linked.appending(path: "second-name.json").path) == 0)
        let multiplyLinked = #expect(throws: ProcessIdentityStoreError.self) { try ProcessIdentityStore(directory: linked) }
        guard case .unreadable(_, let linkReason)? = multiplyLinked else { Issue.record("expected unreadable, got \(String(describing: multiplyLinked))"); return }
        #expect(linkReason.contains("more than one name"))

        let oversized = try makeDirectory()
        let file = oversized.appending(path: ProcessIdentityStore.fileName)
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ProcessIdentityStore.maximumFileSize) + 1)
        try handle.close()
        let tooLarge = #expect(throws: ProcessIdentityStoreError.self) { try ProcessIdentityStore(directory: oversized) }
        guard case .unreadable(_, let sizeReason)? = tooLarge else { Issue.record("expected unreadable, got \(String(describing: tooLarge))"); return }
        #expect(sizeReason.contains("too large"), "the size is refused before the bytes are read")
    }

    /// The descriptor keeps naming the folder that was opened, so nothing is ever written
    /// through whatever takes its name. A write into a folder the next launch will not open is
    /// not durable either, and reporting it as recorded would strand a VM that is running.
    @Test func aRecordIsRefusedWhenTheStateFolderIsNoLongerAtItsPath() async throws {
        let original = try makeDirectory()
        let store = try ProcessIdentityStore(directory: original)
        let moved = original.deletingLastPathComponent().appending(path: "Moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: original, to: moved)
        // Something else now answers to the name the store was given.
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let environment = EnvironmentID()
        let identity = ProcessIdentity(pid: 1, startTime: Date(), executablePath: "/x", argumentsDigest: "sha256:0", vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        await #expect(throws: ProcessIdentityStoreError.self) { try await store.record(identity) }
        #expect(!FileManager.default.fileExists(atPath: moved.appending(path: ProcessIdentityStore.fileName).path), "nothing was written where the next launch will not look")
        #expect(!FileManager.default.fileExists(atPath: original.appending(path: ProcessIdentityStore.fileName).path), "nothing was written through whatever took the folder's name")
        #expect(await store.identity(for: environment) == nil, "a refused write leaves the store describing the disk")
    }

    /// Two stores can be open on one directory — a reload while the first is still live — and
    /// the second's cleanup must not unlink the write the first is about to rename into place.
    @Test func staleTemporaryCleanupSkipsAnotherStoresLiveWrite() async throws {
        let directory = try makeDirectory()
        let store = try ProcessIdentityStore(directory: directory)
        let live = directory.appending(path: ".\(ProcessIdentityStore.fileName).tmp-\(UUID().uuidString)")
        let leftover = directory.appending(path: ".\(ProcessIdentityStore.fileName).tmp-\(UUID().uuidString)")
        try Data("live".utf8).write(to: live)
        try Data("leftover".utf8).write(to: leftover)
        let held = open(live.path, O_RDONLY)
        try #require(held >= 0)
        defer { close(held) }
        try #require(flock(held, LOCK_EX | LOCK_NB) == 0)

        _ = try ProcessIdentityStore(directory: directory)
        #expect(FileManager.default.fileExists(atPath: live.path), "a temporary another store still holds is its live write")
        #expect(!FileManager.default.fileExists(atPath: leftover.path), "an unheld temporary is a leftover and goes")
        _ = store
    }

    /// A temporary is visible under its name from the moment `openat` creates it, which is
    /// before its writer can `flock` it. A store opening the folder in that window would find
    /// an unlocked file and unlink a live write, so cleanup waits for the same folder lock
    /// every update is made under.
    @Test func staleTemporaryCleanupWaitsForTheFolderLock() throws {
        let directory = try makeDirectory()
        let temporary = directory.appending(path: ".\(ProcessIdentityStore.fileName).tmp-\(UUID().uuidString)")
        try Data("a write that has not been locked yet".utf8).write(to: temporary)
        // The lock a writing store holds across its whole read-modify-write.
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(folder >= 0)
        defer { close(folder) }
        try #require(flock(folder, LOCK_EX | LOCK_NB) == 0)

        // Opened on a thread of its own: the store blocks on the folder lock, and a blocked
        // cooperative thread would be one the rest of the suite cannot use.
        let opened = DispatchSemaphore(value: 0)
        let thread = Thread {
            _ = try? ProcessIdentityStore(directory: directory)
            opened.signal()
        }
        thread.start()
        #expect(opened.wait(timeout: .now() + .milliseconds(250)) == .timedOut, "the store finished its cleanup while another writer held the folder")
        #expect(FileManager.default.fileExists(atPath: temporary.path), "a live write survives a store opening beside it")
        #expect(flock(folder, LOCK_UN) == 0)
        #expect(opened.wait(timeout: .now() + .seconds(10)) == .success)
        #expect(!FileManager.default.fileExists(atPath: temporary.path), "once no writer holds the folder the leftover goes")
    }

    /// Each store stages its change onto the document on disk, not onto the copy it read when
    /// it opened, so the second write cannot drop the first store's record and strand the VM
    /// that record is the ownership evidence for.
    @Test func aWriteThroughOneStoreKeepsWhatAnotherAlreadyRecorded() async throws {
        let directory = try makeDirectory()
        let first = try ProcessIdentityStore(directory: directory)
        // Opened while the first is still live and while the document is still empty: this is
        // the snapshot that would overwrite the other store's record.
        let second = try ProcessIdentityStore(directory: directory)
        let one = EnvironmentID(), two = EnvironmentID()
        try await first.record(identity(for: one, pid: 11))
        // The record is published by renaming a temporary `openat` created, and `openat` masks
        // its mode with the umask: a document the next launch cannot reopen is ownership
        // evidence lost.
        var published = stat()
        #expect(stat(directory.appending(path: ProcessIdentityStore.fileName).path, &published) == 0)
        #expect(published.st_mode & 0o777 == 0o600, "the published record is private and still readable by its owner")
        try await second.record(identity(for: two, pid: 22))
        let reloaded = try ProcessIdentityStore(directory: directory)
        #expect(await reloaded.identity(for: one)?.pid == 11, "the record the first store wrote survived the second store's write")
        #expect(await reloaded.identity(for: two)?.pid == 22)
        #expect(await second.identity(for: one)?.pid == 11, "the writing store describes the whole document, not only its own change")
        // A removal through one store is equally visible to the other's next write.
        try await first.remove(one)
        try await second.record(identity(for: two, pid: 23))
        #expect(await (try ProcessIdentityStore(directory: directory)).all.count == 1)
        #expect(await second.identity(for: one) == nil)
    }

    private func identity(for environment: EnvironmentID, pid: pid_t) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startTime: Date(timeIntervalSince1970: 1_800_000_000),
            executablePath: "/x",
            argumentsDigest: "sha256:0",
            vmName: environment.tartVMName,
            environmentID: environment,
            recordedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }
}
