import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.serialized) struct EnvironmentLifecycleTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "LifecycleTests-\(UUID().uuidString)")
    let environment = EnvironmentID()

    func entryJSON(_ name: String, running: Bool) -> String {
        #"{"Source":"local","Name":"\#(name)","Disk":160,"Size":20,"Accessed":"2026-09-03T00:00:00Z","Running":\#(running),"State":"\#(running ? "running" : "stopped")"}"#
    }

    func listJSON(running: Bool, extra: [String] = []) -> String {
        var entries = [entryJSON(environment.tartVMName, running: running)]
        entries += extra.map { #"{"Source":"local","Name":"\#($0)","Disk":1,"Size":1,"Accessed":"2026-09-03T00:00:00Z","Running":false,"State":"stopped"}"# }
        return "[" + entries.joined(separator: ",") + "]"
    }

    func makeStorage() throws -> (RuntimeStorage, StateStore) {
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        return (storage, try StateStore(rootURL: storage.url(for: .state)))
    }

    /// A lifecycle over storage the test already holds, so a snapshot or a journal record can
    /// be seeded before the service starts.
    func makeLifecycle(runner: FakeProcessRunner, storage: RuntimeStorage, store: StateStore, recordedIdentities: [ProcessIdentity] = []) async throws -> EnvironmentLifecycle {
        let bundle = TartBundle(url: storage.url(for: .runtime).appending(path: "tart.app"))
        // The fixture's executable is a link to the test helper: it accepts any arguments,
        // leaves them untouched, and runs until ended, so `run` looks like a live VM process
        // whose recorded identity keeps verifying. (A copied system binary would be killed at
        // launch: platform binaries only run in place.)
        try FileManager.default.createDirectory(at: bundle.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bundle.executable, withDestinationURL: try TestHelper.executable())
        let identities = try ProcessIdentityStore(directory: storage.url(for: .state))
        for identity in recordedIdentities { try await identities.record(identity) }
        let supervisor = OperationSupervisor(store: identities)
        return EnvironmentLifecycle(dependencies: .init(backend: TartBackend(bundle: bundle, storage: storage, runner: runner), supervisor: supervisor, store: store))
    }

    func makeLifecycle(runner: FakeProcessRunner, recordedIdentities: [ProcessIdentity] = []) async throws -> (EnvironmentLifecycle, StateStore, RuntimeStorage) {
        let (storage, store) = try makeStorage()
        let lifecycle = try await makeLifecycle(runner: runner, storage: storage, store: store, recordedIdentities: recordedIdentities)
        return (lifecycle, store, storage)
    }

    /// Saves the environment into the snapshot, so a test does not depend on adoption having
    /// read the inventory.
    func seedSnapshot(in store: StateStore) async throws {
        var snapshot = try await store.loadSnapshot()
        snapshot.environments.append(DevelopmentEnvironment(id: environment, name: environment.tartVMName, createdAt: Date()))
        try snapshot.slots.reserve(environment)
        try await store.saveSnapshot(snapshot)
    }

    /// Replaces the journal with a symbolic link, which the store refuses to open, and returns
    /// what it held so the test can put it back.
    func breakJournal(in storage: RuntimeStorage) throws -> Data {
        let journal = storage.url(for: .state).appending(path: "journal.ndjson")
        let original = try Data(contentsOf: journal)
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        return original
    }

    func repairJournal(in storage: RuntimeStorage, with original: Data) throws {
        let journal = storage.url(for: .state).appending(path: "journal.ndjson")
        try FileManager.default.removeItem(at: journal)
        try original.write(to: journal)
    }

    /// Waits until the environment is no longer reported as running.
    func waitUntilNotRunning(_ lifecycle: EnvironmentLifecycle) async throws {
        for _ in 0..<400 {
            if try await lifecycle.status(of: environment).vm != .running { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A runner that behaves like Tart for one VM: `list`, `run` (hangs until `stop`), `ip`, `stop`.
    func tartLikeRunner(running: Bool = false, ip: String = "192.168.64.7") -> FakeProcessRunner {
        FakeProcessRunner(script: [
            "list": .init(stdout: [listJSON(running: running, extra: ["ubuntu"])]),
            "run": .init(hangs: true),
            "ip": .init(stdout: [ip]),
            "stop": .init(),
        ])
    }

    func collect(_ events: EventCollector, until terminal: Int = 1) async -> [RuntimeEvent] {
        for _ in 0..<400 {
            let seen = events.events
            if seen.contains(where: { if case .completed = $0 { true } else if case .failed = $0 { true } else { false } }) { return seen }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return events.events
    }

    @Test func anInterruptedOperationIsSettledOnceTheVMIsConfirmedStopped() async throws {
        let runner = tartLikeRunner()
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let store = try StateStore(rootURL: storage.url(for: .state))
        let interrupted = try await store.begin(.startEnvironment, for: environment)
        let bundle = TartBundle(url: storage.url(for: .runtime).appending(path: "tart.app"))
        try FileManager.default.createDirectory(at: bundle.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bundle.executable, withDestinationURL: try TestHelper.executable())
        let supervisor = OperationSupervisor(store: try ProcessIdentityStore(directory: storage.url(for: .state)))
        let lifecycle = EnvironmentLifecycle(dependencies: .init(backend: TartBackend(bundle: bundle, storage: storage, runner: runner), supervisor: supervisor, store: store))
        try await lifecycle.prepare()
        let replay = try await store.replay()
        #expect(replay.inFlight.isEmpty, "the interrupted start was closed by reconciliation")
        #expect(replay.records.last?.id == interrupted)
        #expect(replay.records.last?.outcome == .reconciled)
        #expect(try await lifecycle.status(of: environment).readiness == .ready)
    }

    @Test func aRunningVMWithoutOwnershipEvidenceBlocksStartAndForceStop() async throws {
        let runner = tartLikeRunner(running: true)
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let status = try await lifecycle.status(of: environment)
        guard case .uncertain = status.vm else { Issue.record("expected uncertain, got \(status.vm)"); return }
        #expect(status.readiness == .needsAttention(.vmOwnershipUncertain(environment)))
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(environment)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(environment)) {
            _ = try await lifecycle.stop(environment, mode: .force) { _ in }
        }
    }

    @Test func aSecondVMIsRefusedWhileOneRuns() async throws {
        let other = EnvironmentID()
        let runner = FakeProcessRunner(script: [
            "list": .init(stdout: [listJSON(running: false, extra: [other.tartVMName])]),
            "run": .init(hangs: true), "ip": .init(stdout: ["192.168.64.9"]), "stop": .init(),
        ])
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        #expect(await lifecycle.environments().count == 2)
        let events = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in events.add(event) }
        _ = await collect(events)
        await #expect(throws: GuesthouseError.anotherEnvironmentRunning(environment)) {
            _ = try await lifecycle.start(other, options: StartOptions()) { _ in }
        }
        await runner.finishHanging()
    }

    @Test func aPreservedEnvironmentIsRefused() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        var snapshot = try await store.loadSnapshot()
        try snapshot.slots.markPreserved(environment)
        try await store.saveSnapshot(snapshot)
        try await lifecycle.prepare()
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.environmentPreserved(environment)))
        await #expect(throws: GuesthouseError.environmentPreserved(environment)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
    }

    @Test func aGracefulStopThatMissesItsDeadlineIsReportedNotForced() async throws {
        let runner = tartLikeRunner()
        await runner.set("stop", .init(hangs: true))
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        let stopEvents = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .milliseconds(300))) { event in stopEvents.add(event) }
        let seen = await collect(stopEvents)
        #expect(seen.last == .failed(stop, .gracefulStopTimedOut(environment)))
        #expect(try await lifecycle.status(of: environment).vm == .running, "the guest was not force-stopped")
        let stopInvocation = await runner.invocations.last { $0.arguments.first == "stop" }
        #expect(stopInvocation?.arguments == ["stop", environment.tartVMName, "--timeout", String(TartBackend.neverForceSeconds)])
        await runner.finishHanging()
    }

    @Test func adoptsOnlyAppManagedVMsIntoFreeSlots() async throws {
        let (lifecycle, store, _) = try await makeLifecycle(runner: tartLikeRunner())
        try await lifecycle.prepare()
        let environments = await lifecycle.environments()
        #expect(environments.map(\.id) == [environment])
        #expect(environments[0].name == environment.tartVMName)
        let snapshot = try await store.loadSnapshot()
        #expect(snapshot.slots.state(of: environment) == .active)
        #expect(snapshot.environments.count == 1)
        let status = try await lifecycle.status(of: environment)
        #expect(status.vm == .stopped)
        #expect(status.readiness == .ready)
        #expect(status.inFlightOperation == nil)
    }

    @Test func startJournalsBeforeReportingThenSupervisesAndResolvesTheAddress() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let operation = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(3))) { event in events.add(event) }
        let replay = try await store.replay()
        #expect(replay.inFlight[operation]?.outcome == .started, "the started record is durable before start() returns")

        let seen = await collect(events)
        #expect(seen.map(\.caseName) == ["progress", "progress", "status", "completed"])
        guard let statusEvent = seen.first(where: { if case .status = $0 { true } else { false } }), case .status(let status) = statusEvent else { Issue.record("no status in \(seen)"); return }
        #expect(status.vm == .running)
        #expect(status.guestAddress?.rawValue == "192.168.64.7")
        #expect(try await store.replay().inFlight.isEmpty, "completed is journaled")

        let invocations = await runner.invocations.map(\.arguments)
        #expect(invocations.contains(["run", environment.tartVMName, "--no-graphics"]))
        #expect(invocations.contains(["ip", environment.tartVMName, "--wait", "3"]))
        for invocation in await runner.invocations { #expect(invocation.environment.keys.sorted() == ["TART_HOME"]) }

        await #expect(throws: GuesthouseError.environmentAlreadyRunning(environment)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        // The fake's `run` is a real child process that outlives the test until its own
        // timeout; every test that starts one ends it.
        await runner.finishHanging()
    }

    @Test func nativeConsoleOmitsNoGraphics() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(console: .native, ipWait: .seconds(1))) { event in events.add(event) }
        _ = await collect(events)
        #expect(await runner.invocations.map(\.arguments).contains(["run", environment.tartVMName]))
        await runner.finishHanging()
    }

    @Test func secondOperationWhileOneIsInFlightIsRefused() async throws {
        let runner = tartLikeRunner()
        await runner.set("ip", .init(hangs: true))
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let operation = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(30))) { _ in }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: GuesthouseError.operationInFlight(operation)) {
            _ = try await lifecycle.stop(environment, mode: .force) { _ in }
        }
        #expect(try await lifecycle.status(of: environment).inFlightOperation == operation)
        await runner.finishHanging()
    }

    @Test func unreachableGuestFailsTheStartButKeepsSupervising() async throws {
        let runner = tartLikeRunner()
        await runner.set("ip", .init(stderr: ["no IP address found, is your VM running?"], exit: ProcessExit(reason: .status(1))))
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let operation = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in events.add(event) }
        let seen = await collect(events)
        #expect(seen.last == .failed(operation, .guestNotReachable(environment)))
        #expect(try await store.replay().inFlight.isEmpty)
        #expect(try await lifecycle.status(of: environment).vm == .running, "the VM process is still supervised")
        await runner.finishHanging()
    }

    @Test func gracefulStopWaitsForTheProcessAndReleasesTheSlotState() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)

        let stopEvents = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .seconds(20))) { event in stopEvents.add(event) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(stopEvents.events.map(\.caseName) == ["progress"], "waits for the VM process to exit")
        await runner.finishHanging()
        let seen = await collect(stopEvents)
        #expect(seen.map(\.caseName) == ["progress", "status", "completed"])
        guard let statusEvent = seen.first(where: { if case .status = $0 { true } else { false } }), case .status(let status) = statusEvent else { Issue.record("no status in \(seen)"); return }
        #expect(status.vm == .stopped)
        #expect(await runner.invocations.map(\.arguments).contains(["stop", environment.tartVMName, "--timeout", String(TartBackend.neverForceSeconds)]), "Tart's own force-stop is never reached by a graceful request")
        #expect(try await store.replay().inFlight.isEmpty)
        _ = stop
    }

    @Test func forceStopTerminatesTheSupervisedProcess() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        let stopEvents = EventCollector()
        _ = try await lifecycle.stop(environment, mode: .force) { event in stopEvents.add(event) }
        let seen = await collect(stopEvents)
        #expect(seen.map(\.caseName) == ["progress", "status", "completed"])
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "stop" }), "force stop does not go through tart stop while the process is supervised")
    }

    @Test func uncertainOwnershipBlocksStartUntilRepaired() async throws {
        let runner = tartLikeRunner(running: true)
        let stale = ProcessIdentity(pid: 2_000_000_000, startTime: Date(), executablePath: "/nowhere/tart", argumentsDigest: "sha256:x", vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner, recordedIdentities: [stale])
        try await lifecycle.prepare()
        let status = try await lifecycle.status(of: environment)
        guard case .uncertain = status.vm else { Issue.record("expected uncertain, got \(status.vm)"); return }
        #expect(status.readiness == .needsAttention(.vmOwnershipUncertain(environment)))
        await #expect(throws: GuesthouseError.self) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
    }

    @Test func stoppingAVMThatIsAlreadyStoppedCompletes() async throws {
        let runner = tartLikeRunner(running: false)
        await runner.set("stop", .init(stderr: ["vm \"\(environment.tartVMName)\" is not running"], exit: ProcessExit(reason: .status(1))))
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .seconds(5))) { event in events.add(event) }
        let seen = await collect(events)
        #expect(seen.last == .completed(stop), "the requested state was already reached")
        #expect(try await lifecycle.status(of: environment).vm == .stopped)
        #expect(try await store.replay().inFlight.isEmpty)
    }

    @Test func cancelDuringAProtectedPhaseIsDeferredNotApplied() async throws {
        let runner = tartLikeRunner()
        await runner.set("stop", .init(hangs: true))
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        let stopEvents = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .seconds(20))) { event in stopEvents.add(event) }
        for _ in 0..<200 where stopEvents.events.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(stopEvents.events.first == .progress(stop, ProgressPhase(kind: .stoppingVM, cancelable: false)))
        await lifecycle.cancel(stop)
        try await Task.sleep(for: .milliseconds(150))
        #expect(stopEvents.events.count == 1, "a protected phase keeps running after a cancel request")
        await runner.finishHanging()
        let seen = await collect(stopEvents)
        #expect(!seen.contains(.failed(stop, .canceled)), "the stop reports its real outcome, never a cancellation")
    }

    @Test func anUncertainVerdictIsReconciledAgainWhenStatusIsInspected() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        await runner.set("list", .init(stderr: ["cannot read inventory"], exit: ProcessExit(reason: .status(1))))
        await lifecycle.reconcile()
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(environment)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        await runner.set("list", .init(stdout: [listJSON(running: false)]))
        let status = try await lifecycle.status(of: environment)
        #expect(status.vm == .stopped, "a readable inventory clears the uncertainty without a restart")
        #expect(status.readiness == .ready)
    }

    @Test func aForceStopOfAnAdoptedSurvivorSignalsTheVerifiedProcess() async throws {
        let survivor = try await ProcessRunner().run(ProcessInvocation(executable: try TestHelper.executable(), arguments: ["run", environment.tartVMName, "--no-graphics"], timeout: .seconds(60)))
        let enumerator = LiveProcessEnumerator()
        let live = try #require(enumerator.live(pid: survivor.processIdentifier))
        let identity = ProcessIdentity(pid: live.pid, startTime: live.startTime, executablePath: live.executablePath, argumentsDigest: live.argumentsDigest, vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        let runner = tartLikeRunner(running: true)
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner, recordedIdentities: [identity])
        try await lifecycle.prepare()
        let adopted = try await lifecycle.status(of: environment)
        #expect(adopted.vm == .running)
        #expect(adopted.guestAddress != nil, "an adopted survivor's address is looked up")
        let events = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .force) { event in events.add(event) }
        let seen = await collect(events)
        #expect(seen.last == .completed(stop))
        #expect(enumerator.live(pid: survivor.processIdentifier) == nil, "the adopted process was ended")
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "stop" }), "no graceful tart stop stands in for a force-stop")
    }

    @Test func aFailureTheJournalCannotRecordStaysUnresolved() async throws {
        let runner = tartLikeRunner()
        // The address lookup hangs; once the start is waiting for it the journal is made
        // unwritable and the operation is canceled, so its terminal record cannot be written.
        await runner.set("ip", .init(hangs: true))
        let (lifecycle, store, storage) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let state = storage.url(for: .state)
        let start = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in events.add(event) }
        for _ in 0..<400 where events.events.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(events.events.last == .progress(start, ProgressPhase(kind: .waitingForNetwork)))
        // The journal file is replaced by a symbolic link, which the store refuses to open.
        let journal = state.appending(path: "journal.ndjson")
        let original = try Data(contentsOf: journal)
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        defer { try? FileManager.default.removeItem(at: journal); try? original.write(to: journal) }
        await lifecycle.cancel(start)
        let seen = await collect(events)
        await runner.finishHanging()
        #expect(seen.last == .failed(start, .operationOutcomeUnknown(start)), "an unrecorded failure is reported as unknown, never as a plain failure")
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.operationOutcomeUnknown(start)))
        await #expect(throws: GuesthouseError.operationOutcomeUnknown(start)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        _ = store
    }

    @Test func aGracefulStopOfAVMWithoutOwnershipEvidenceIsRefused() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        // Something outside Guesthouse started the app-named VM after the last reconciliation,
        // so there is no verdict for it at all.
        await runner.set("list", .init(stdout: [listJSON(running: true)]))
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(environment)) {
            _ = try await lifecycle.stop(environment, mode: .graceful(deadline: .seconds(5))) { _ in }
        }
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "stop" }), "a guest that is not ours is never shut down by name")
    }

    @Test func aForceStopCompletesWhenTheGuestAlreadyStopped() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        // The guest finishes shutting down before the warned force-stop is confirmed.
        await runner.finishHanging()
        try await waitUntilNotRunning(lifecycle)
        let events = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .force) { event in events.add(event) }
        let seen = await collect(events)
        #expect(seen.last == .completed(stop), "the requested stopped state was already reached")
        #expect(try await store.replay().inFlight.isEmpty)
    }

    @Test func anUnreadableInventoryAtLaunchDoesNotFailTheService() async throws {
        let (storage, store) = try makeStorage()
        try await seedSnapshot(in: store)
        let runner = tartLikeRunner()
        await runner.set("list", .init(stderr: ["cannot read inventory"], exit: ProcessExit(reason: .status(1))))
        let lifecycle = try await makeLifecycle(runner: runner, storage: storage, store: store)
        try await lifecycle.prepare()
        #expect(await lifecycle.environments().map(\.id) == [environment], "the saved environments are still served")
    }

    @Test func aReconciliationTheJournalCannotRecordStaysUnresolvedUntilStorageIsRepaired() async throws {
        let (storage, store) = try makeStorage()
        try await seedSnapshot(in: store)
        let interrupted = try await store.begin(.startEnvironment, for: environment)
        let runner = tartLikeRunner()
        // Nothing settles while the inventory is unreadable.
        await runner.set("list", .init(stderr: ["cannot read inventory"], exit: ProcessExit(reason: .status(1))))
        let lifecycle = try await makeLifecycle(runner: runner, storage: storage, store: store)
        try await lifecycle.prepare()

        let original = try breakJournal(in: storage)
        await runner.set("list", .init(stdout: [listJSON(running: false)]))
        await lifecycle.reconcile()
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.operationOutcomeUnknown(interrupted)),
                "an unwritten terminal record leaves the operation in flight")

        try repairJournal(in: storage, with: original)
        #expect(try await lifecycle.status(of: environment).readiness == .ready, "inspection settles it once storage works, without a restart")
        #expect(try await store.replay().inFlight.isEmpty)
    }

    @Test func aPreservedEnvironmentStillAsksForTheUnknownOutcomeFirst() async throws {
        let (storage, store) = try makeStorage()
        try await seedSnapshot(in: store)
        var snapshot = try await store.loadSnapshot()
        try snapshot.slots.markPreserved(environment)
        try await store.saveSnapshot(snapshot)
        let interrupted = try await store.begin(.stopEnvironment, for: environment)
        let runner = tartLikeRunner()
        await runner.set("list", .init(stderr: ["cannot read inventory"], exit: ProcessExit(reason: .status(1))))
        let lifecycle = try await makeLifecycle(runner: runner, storage: storage, store: store)
        try await lifecycle.prepare()

        _ = try breakJournal(in: storage)
        await runner.set("list", .init(stdout: [listJSON(running: false)]))
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.operationOutcomeUnknown(interrupted)),
                "preservation does not hide the operation that has to be inspected first")
    }

    @Test func aRunningAppManagedVMWithoutASlotRefusesAStart() async throws {
        let filler = EnvironmentID()
        let unadopted = EnvironmentID()
        // The two slots are taken before the running VM is reached, so it is app-managed and
        // running yet absent from the snapshot.
        let inventory = [
            entryJSON(environment.tartVMName, running: false),
            entryJSON(filler.tartVMName, running: false),
            entryJSON(unadopted.tartVMName, running: true),
        ]
        let runner = FakeProcessRunner(script: [
            "list": .init(stdout: ["[" + inventory.joined(separator: ",") + "]"]),
            "run": .init(hangs: true), "ip": .init(stdout: ["192.168.64.9"]), "stop": .init(),
        ])
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        #expect(await lifecycle.environments().count == 2, "the third VM found no free slot")
        await #expect(throws: GuesthouseError.anotherEnvironmentRunning(unadopted)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
    }

    @Test func statusRefreshesTheGuestAddressOnEveryInspection() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in events.add(event) }
        _ = await collect(events)
        #expect(try await lifecycle.status(of: environment).guestAddress?.rawValue == "192.168.64.7")
        // Tart handed the same live VM a different address, as it does after the host sleeps.
        await runner.set("ip", .init(stdout: ["192.168.64.31"]))
        #expect(try await lifecycle.status(of: environment).guestAddress?.rawValue == "192.168.64.31")
        await runner.finishHanging()
    }

    @Test func aVMThatExitsWhileItsAddressIsLookedUpDoesNotCompleteTheStart() async throws {
        let runner = tartLikeRunner()
        // Slow enough that the VM process can end while the lookup is still in flight.
        await runner.set("ip", .init(stdout: ["192.168.64.7"], delay: .milliseconds(600)))
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let operation = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(5))) { event in events.add(event) }
        for _ in 0..<400 where events.events.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(events.events.last == .progress(operation, ProgressPhase(kind: .waitingForNetwork)))
        await runner.finishHanging(command: "run")
        let seen = await collect(events)
        #expect(seen.last == .failed(operation, .guestNotReachable(environment)), "an address for a VM that is gone is not a completed start")
        #expect(try await store.replay().inFlight.isEmpty)
    }

    @Test func aStopWhoseDeadlineExpiresAfterTheGuestStoppedIsNotATimeout() async throws {
        let runner = tartLikeRunner()
        await runner.set("stop", .init(hangs: true))
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        let events = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .milliseconds(700))) { event in events.add(event) }
        for _ in 0..<400 where events.events.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        // The guest completes its shutdown while `tart stop` is still being waited on.
        await runner.finishHanging(command: "run")
        let seen = await collect(events)
        #expect(seen.last == .completed(stop), "the deadline expired after the shutdown finished, so nothing timed out")
        #expect(try await store.replay().inFlight.isEmpty)
        await runner.finishHanging()
    }

    @Test func theWaitForTartToExitEndsAtTheStopDeadline() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        // `tart stop` answers, but the process hosting the VM keeps running past the deadline.
        let events = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .milliseconds(300))) { event in events.add(event) }
        let seen = await collect(events)
        #expect(seen.last == .failed(stop, .operationOutcomeUnknown(stop)), "the wait ends at the deadline with the outcome unestablished")
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.operationOutcomeUnknown(stop)))
        await runner.finishHanging()
    }

    @Test func anInterruptedStopStaysUnresolvedWhileTheVMIsStillRunning() async throws {
        let survivor = try await ProcessRunner().run(ProcessInvocation(executable: try TestHelper.executable(), arguments: ["run", environment.tartVMName, "--no-graphics"], timeout: .seconds(60)))
        defer { survivor.terminate(gracePeriod: .milliseconds(100)) }
        let live = try #require(LiveProcessEnumerator().live(pid: survivor.processIdentifier))
        let identity = ProcessIdentity(pid: live.pid, startTime: live.startTime, executablePath: live.executablePath, argumentsDigest: live.argumentsDigest, vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        let (storage, store) = try makeStorage()
        let lifecycle = try await makeLifecycle(runner: tartLikeRunner(running: true), storage: storage, store: store, recordedIdentities: [identity])
        let interrupted = try await store.begin(.stopEnvironment, for: environment)
        try await lifecycle.prepare()
        #expect(try await store.replay().inFlight[interrupted] != nil, "a running VM does not prove the shutdown finished")
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.operationOutcomeUnknown(interrupted)))
        await #expect(throws: GuesthouseError.operationOutcomeUnknown(interrupted)) {
            _ = try await lifecycle.stop(environment, mode: .force) { _ in }
        }
    }

    @Test func aProcessRecordThatCannotBeRemovedLeavesTheEnvironmentUncertain() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, storage) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in events.add(event) }
        _ = await collect(events)
        // The state folder stops accepting new files, so `processes.json` cannot be rewritten
        // while the journal, whose file already exists, still can be.
        let state = storage.url(for: .state)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path) }
        await runner.finishHanging()
        try await waitUntilNotRunning(lifecycle)
        let status = try await lifecycle.status(of: environment)
        guard case .uncertain = status.vm else { Issue.record("expected uncertain, got \(status.vm)"); return }
        #expect(status.readiness == .needsAttention(.vmOwnershipUncertain(environment)))
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(environment)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
    }

    @Test func anUnreadableInventoryIsAStateFailureNotAnUnreachableGuest() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        await runner.set("list", .init(stderr: ["tart: the virtual machine directory could not be read"], exit: ProcessExit(reason: .status(1))))
        do {
            _ = try await lifecycle.status(of: environment)
            Issue.record("expected the inventory failure to be reported")
        } catch let error as GuesthouseError {
            #expect(error.caseName == "runtimeStateUnavailable", "no guest network was probed, so this is not a reachability failure")
            #expect(error.recoveryActions.contains(.inspectState))
        }
    }

    @Test func aCaptureCutOffByTheRecordLimitIsRefused() async throws {
        let (storage, store) = try makeStorage()
        // A parseable prefix followed by more records than the cap allows: without the limit
        // being reported, the parser's answer would be trusted although it never saw the rest.
        let padded = [listJSON(running: false)] + Array(repeating: "", count: TartBackend.maximumCapturedRecords)
        let runner = FakeProcessRunner(script: ["list": .init(stdout: padded)])
        _ = try await makeLifecycle(runner: runner, storage: storage, store: store)
        let bundle = TartBundle(url: storage.url(for: .runtime).appending(path: "tart.app"))
        let backend = TartBackend(bundle: bundle, storage: storage, runner: runner)
        await #expect(throws: TartInvocationError.unparseableOutput) { _ = try await backend.list() }
    }

    @Test func unknownEnvironmentIsRefused() async throws {
        let (lifecycle, _, _) = try await makeLifecycle(runner: tartLikeRunner())
        try await lifecycle.prepare()
        let stranger = EnvironmentID()
        await #expect(throws: GuesthouseError.environmentNotFound(stranger)) { _ = try await lifecycle.status(of: stranger) }
        await #expect(throws: GuesthouseError.environmentNotFound(stranger)) { _ = try await lifecycle.start(stranger, options: StartOptions()) { _ in } }
    }
}

/// Records events synchronously in delivery order; the sink closure calls `add` directly.
final class EventCollector: Sendable {
    private let storage = Mutex<[RuntimeEvent]>([])
    var events: [RuntimeEvent] { storage.withLock { $0 } }
    func add(_ event: RuntimeEvent) { storage.withLock { $0.append(event) } }
}

/// The fixture executable built alongside the tests (`GuesthouseKitTestHelper`): SwiftPM and
/// Xcode both place package executables next to the test bundle.
enum TestHelper {
    static func executable() throws -> URL {
        let bundle = Bundle(for: EventCollector.self).bundleURL
        let candidates = [
            bundle.deletingLastPathComponent().appending(path: "GuesthouseKitTestHelper"),
            bundle.deletingLastPathComponent().deletingLastPathComponent().appending(path: "GuesthouseKitTestHelper"),
        ]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw TestHelperError.notBuilt(candidates.map(\.path))
        }
        return found
    }

    enum TestHelperError: Error { case notBuilt([String]) }
}
