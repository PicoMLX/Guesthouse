import Darwin
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
    func makeLifecycle(runner: FakeProcessRunner, storage: RuntimeStorage, store: StateStore, recordedIdentities: [ProcessIdentity] = [], enumerator: LiveProcessEnumerator = LiveProcessEnumerator()) async throws -> EnvironmentLifecycle {
        let bundle = TartBundle(url: storage.url(for: .runtime).appending(path: "tart.app"))
        // The fixture's executable is a link to the test helper: it accepts any arguments,
        // leaves them untouched, and runs until ended, so `run` looks like a live VM process
        // whose recorded identity keeps verifying. (A copied system binary would be killed at
        // launch: platform binaries only run in place.)
        try FileManager.default.createDirectory(at: bundle.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bundle.executable, withDestinationURL: try TestHelper.executable())
        let identities = try ProcessIdentityStore(directory: storage.url(for: .state))
        for identity in recordedIdentities { try await identities.record(identity) }
        let supervisor = OperationSupervisor(store: identities, enumerator: enumerator)
        return EnvironmentLifecycle(dependencies: .init(backend: TartBackend(bundle: bundle, storage: storage, runner: runner), supervisor: supervisor, store: store))
    }

    func makeLifecycle(runner: FakeProcessRunner, recordedIdentities: [ProcessIdentity] = [], enumerator: LiveProcessEnumerator = LiveProcessEnumerator()) async throws -> (EnvironmentLifecycle, StateStore, RuntimeStorage) {
        let (storage, store) = try makeStorage()
        let lifecycle = try await makeLifecycle(runner: runner, storage: storage, store: store, recordedIdentities: recordedIdentities, enumerator: enumerator)
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

    func collect(_ events: EventCollector, deadline: Duration = .seconds(2)) async -> [RuntimeEvent] {
        let end = ContinuousClock.now.advanced(by: deadline)
        while true {
            let seen = events.events
            if seen.contains(where: { if case .completed = $0 { true } else if case .failed = $0 { true } else { false } }) { return seen }
            if ContinuousClock.now >= end { return seen }
            try? await Task.sleep(for: .milliseconds(5))
        }
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
        #expect(try await lifecycle.environments().count == 2)
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
        let environments = try await lifecycle.environments()
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
        // The launch survives it: the service still exists and can be asked again.
        try await lifecycle.prepare()
        // The listing itself does not pretend to have succeeded. It could not be completed, so
        // it reports the inventory failure with its recovery rather than a list that may be
        // missing environments.
        await #expect(throws: GuesthouseError.runtimeStateUnavailable(reason: SanitizedText("the list of virtual machines could not be read", limit: 200))) {
            _ = try await lifecycle.environments()
        }
        await runner.set("list", .init(stdout: [listJSON(running: false)]))
        #expect(try await lifecycle.environments().map(\.id) == [environment], "the saved environments are served once the inventory answers")
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
        #expect(try await lifecycle.environments().count == 2, "the third VM found no free slot")
        // Nothing records that Guesthouse started it, and `stop` would refuse its unregistered
        // id, so "stop it first" is not something the developer could act on: the blocker is
        // reported as the uncertain ownership it is, with inspection and the console.
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(unadopted)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        #expect(GuesthouseError.vmOwnershipUncertain(unadopted).recoveryActions.contains(.inspectState))
        #expect(GuesthouseError.vmOwnershipUncertain(unadopted).recoveryActions.contains(.openConsole))
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

    /// A live process that stands in for a `tart run <vm>` nobody adopted. It is spawned
    /// outside `ProcessRunner` so nothing reaps it; the caller ends it.
    func spawnClaimant(of vmName: String) throws -> pid_t {
        let helper = try TestHelper.executable().path
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), strdup("run"), strdup(vmName), strdup("--no-graphics"), nil]
        defer { for argument in argv { free(argument) } }
        #expect(posix_spawn(&pid, helper, nil, nil, &argv, environ) == 0)
        return pid
    }

    @Test func aStartIsRefusedWhenTheVMIsNoLongerInTheStore() async throws {
        let (storage, store) = try makeStorage()
        try await seedSnapshot(in: store)
        // The registered VM's bundle was removed from TART_HOME, so the inventory no longer
        // names it.
        let runner = FakeProcessRunner(script: [
            "list": .init(stdout: [#"[{"Source":"local","Name":"ubuntu","Disk":1,"Size":1,"Accessed":"2026-09-03T00:00:00Z","Running":false,"State":"stopped"}]"#]),
            "run": .init(hangs: true), "ip": .init(stdout: ["192.168.64.7"]), "stop": .init(),
        ])
        let lifecycle = try await makeLifecycle(runner: runner, storage: storage, store: store)
        try await lifecycle.prepare()
        await #expect(throws: GuesthouseError.environmentNotFound(environment)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "run" }), "a VM that is not there is never launched")
        #expect(try await store.replay().inFlight.isEmpty, "nothing was journaled for a start that cannot happen")
    }

    @Test func aClaimantThatHasNotTakenTheLockRefusesTheStart() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        // A `tart run` for this VM that has spawned but has not taken the lock yet: the
        // inventory still says stopped.
        let claimant = try spawnClaimant(of: environment.tartVMName)
        defer { kill(claimant, SIGKILL); waitpid(claimant, nil, 0) }
        for _ in 0..<200 where LiveProcessEnumerator().live(pid: claimant) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(environment)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "run" }), "two Tart processes never race for one disk")
        #expect(try await store.replay().inFlight.isEmpty)
    }

    @Test func anotherSlotWithUncertainOwnershipBlocksTheStart() async throws {
        let other = EnvironmentID()
        // The other slot's recorded process is alive and claims that slot's VM, but it does not
        // match what was recorded for it, so its ownership is unresolved while the inventory
        // says the VM is stopped.
        let holder = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "sleep 43", "run", other.tartVMName], timeout: .seconds(20)))
        defer { holder.terminate(gracePeriod: .milliseconds(100)) }
        let mismatched = ProcessIdentity(pid: holder.processIdentifier, startTime: Date(timeIntervalSince1970: 0), executablePath: "/usr/bin/perl", argumentsDigest: "sha256:0", vmName: other.tartVMName, environmentID: other, recordedAt: Date(timeIntervalSince1970: 0))
        let runner = FakeProcessRunner(script: [
            "list": .init(stdout: [listJSON(running: false, extra: [other.tartVMName])]),
            "run": .init(hangs: true), "ip": .init(stdout: ["192.168.64.7"]), "stop": .init(),
        ])
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner, recordedIdentities: [mismatched])
        try await lifecycle.prepare()
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(other)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "run" }), "a slot that may still be running blocks the second VM")
    }

    @Test func aDuplicatedInventoryEntryIsAdoptedOnce() async throws {
        // `tart list` is untrusted output: the same VM appearing twice must not produce two
        // records, which would make every later snapshot save fail.
        let repeated = "[" + [entryJSON(environment.tartVMName, running: false), entryJSON(environment.tartVMName, running: false)].joined(separator: ",") + "]"
        let runner = FakeProcessRunner(script: [
            "list": .init(stdout: [repeated]), "run": .init(hangs: true), "ip": .init(stdout: ["192.168.64.7"]), "stop": .init(),
        ])
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        #expect(try await lifecycle.environments().map(\.id) == [environment])
        #expect(try await store.loadSnapshot().environments.count == 1)
    }

    @Test func aVMHiddenByATransientInventoryFailureIsAdoptedOnTheNextListing() async throws {
        let runner = tartLikeRunner()
        await runner.set("list", .init(stderr: ["cannot read inventory"], exit: ProcessExit(reason: .status(1))))
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        await #expect(throws: GuesthouseError.self, "an unreadable inventory reports the failure instead of an empty list") {
            _ = try await lifecycle.environments()
        }
        await runner.set("list", .init(stdout: [listJSON(running: false)]))
        #expect(try await lifecycle.environments().map(\.id) == [environment], "the next listing adopts what the failed one missed")
    }

    @Test func anInterruptedImportIsNotSettledByARunningVM() async throws {
        let survivor = try await ProcessRunner().run(ProcessInvocation(executable: try TestHelper.executable(), arguments: ["run", environment.tartVMName, "--no-graphics"], timeout: .seconds(60)))
        defer { survivor.terminate(gracePeriod: .milliseconds(100)) }
        let live = try #require(LiveProcessEnumerator().live(pid: survivor.processIdentifier))
        let identity = ProcessIdentity(pid: live.pid, startTime: live.startTime, executablePath: live.executablePath, argumentsDigest: live.argumentsDigest, vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        let (storage, store) = try makeStorage()
        let lifecycle = try await makeLifecycle(runner: tartLikeRunner(running: true), storage: storage, store: store, recordedIdentities: [identity])
        // A workspace import was interrupted. A running VM says nothing about how far it got.
        let interrupted = try await store.begin(.importXcode, for: environment)
        try await lifecycle.prepare()
        #expect(try await store.replay().inFlight[interrupted] != nil, "a running VM does not establish what an import changed")
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.operationOutcomeUnknown(interrupted)))
    }

    @Test func anInterruptedImportIsNotSettledByAStoppedVM() async throws {
        let (storage, store) = try makeStorage()
        try await seedSnapshot(in: store)
        // A workspace import was interrupted. The VM being stopped, with no process of ours
        // left, says nothing about what the import wrote into the guest.
        let interrupted = try await store.begin(.importXcode, for: environment)
        let lifecycle = try await makeLifecycle(runner: tartLikeRunner(running: false), storage: storage, store: store)
        try await lifecycle.prepare()
        #expect(try await store.replay().inFlight[interrupted] != nil, "an absent VM does not establish what an import changed")
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.operationOutcomeUnknown(interrupted)))
    }

    @Test func aClaimantOnAnotherSlotAppearingAfterReconciliationRefusesTheStart() async throws {
        let other = EnvironmentID()
        let runner = tartLikeRunner()
        await runner.set("list", .init(stdout: [listJSON(running: false, extra: [other.tartVMName])]))
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        #expect(try await lifecycle.environments().count == 2)
        // The claimant appears after reconciliation, so no remembered verdict names it, and it
        // has not taken its lock yet, so `tart list` still calls that VM stopped. Only a fresh
        // process-table scan of every slot can see it.
        let claimant = try spawnClaimant(of: other.tartVMName)
        defer { kill(claimant, SIGKILL); waitpid(claimant, nil, 0) }
        var seen = false
        for _ in 0..<200 where !seen {
            seen = LiveProcessEnumerator().live(pid: claimant) != nil
            if !seen { try await Task.sleep(for: .milliseconds(5)) }
        }
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(other)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "run" }), "no second VM is launched over a slot something else may be taking")
    }

    @Test func aStopThatCannotLaunchTheRuntimeAsksForRuntimeRepair() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        // The runtime is removed after the stop's ownership preflight has passed, so `tart
        // stop` cannot be launched at all.
        await runner.set("stop", .init(failsToLaunch: true))
        let events = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .seconds(2))) { event in events.add(event) }
        let seen = await collect(events, deadline: .seconds(5))
        #expect(seen.last == .failed(stop, .runtimeMissing), "reinstalling the runtime is what helps, not inspecting saved state")
        #expect(GuesthouseError.runtimeMissing.recoveryActions.contains(.repair(.runtime)))
        await runner.finishHanging()
    }

    @Test func anUnobservableSupervisedProcessIsUncertainNotStopped() async throws {
        let claimant = try spawnClaimant(of: environment.tartVMName)
        defer { kill(claimant, SIGKILL); waitpid(claimant, nil, 0) }
        var live: LiveProcess?
        for _ in 0..<200 where live == nil {
            live = LiveProcessEnumerator().live(pid: claimant)
            if live == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let observed = try #require(live)
        let identity = ProcessIdentity(pid: observed.pid, startTime: observed.startTime, executablePath: observed.executablePath, argumentsDigest: observed.argumentsDigest, vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        // Tart's inventory says the VM is stopped, so nothing but the process table can say
        // otherwise: reading the record as an exit would report the VM as available.
        let (lifecycle, _, _) = try await makeLifecycle(runner: tartLikeRunner(running: false), recordedIdentities: [identity])
        try await lifecycle.prepare()
        #expect(try await lifecycle.status(of: environment).vm == .running)
        // The process is still there but the kernel declines to describe it: "cannot be read"
        // must not be reported as "stopped". (An exited process is a different answer: it holds
        // no VM, and reconciliation says so.)
        let opaque = claimant
        let blind = LiveProcessEnumerator(kernel: .init(
            pids: { LiveProcessEnumerator.listAllPIDs() },
            arguments: { pid in pid == opaque ? nil : LiveProcessEnumerator.readArguments(pid: pid) }
        ))
        guard case .unavailable = blind.observe(pid: claimant) else {
            Issue.record("expected an undescribable process to be unreadable, got \(blind.observe(pid: claimant))")
            return
        }
        let (blindLifecycle, _, _) = try await makeLifecycle(runner: tartLikeRunner(running: false), recordedIdentities: [identity], enumerator: blind)
        try await blindLifecycle.prepare()
        let status = try await blindLifecycle.status(of: environment)
        guard case .uncertain = status.vm else { Issue.record("expected uncertain, got \(status.vm)"); return }
        #expect(status.readiness == .needsAttention(.vmOwnershipUncertain(environment)))
    }

    @Test func aVMThatEndsWhileItsAddressIsLookedUpIsNotReportedRunning() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in events.add(event) }
        _ = await collect(events)
        // The inspection's own address lookup is slow enough for the VM to end while it is in
        // flight; the answer that comes back describes a process that is gone.
        await runner.set("ip", .init(stdout: ["192.168.64.7"], delay: .milliseconds(600)))
        let inspection = Task { try await lifecycle.status(of: environment) }
        try await Task.sleep(for: .milliseconds(150))
        await runner.finishHanging(command: "run")
        let status = try await inspection.value
        #expect(status.vm == .stopped, "an address is no evidence that the VM is still running")
    }

    @Test func anOwnedVerdictIsRevalidatedBeforeAStopIsAuthorized() async throws {
        let survivor = try await ProcessRunner().run(ProcessInvocation(executable: try TestHelper.executable(), arguments: ["run", environment.tartVMName, "--no-graphics"], timeout: .seconds(60)))
        let live = try #require(LiveProcessEnumerator().live(pid: survivor.processIdentifier))
        let identity = ProcessIdentity(pid: live.pid, startTime: live.startTime, executablePath: live.executablePath, argumentsDigest: live.argumentsDigest, vmName: environment.tartVMName, environmentID: environment, recordedAt: Date())
        let runner = tartLikeRunner(running: true)
        // Adoption's address lookup is slow enough that the survivor's exit is noticed while
        // reconciliation is still running, and the verdict it computed earlier is written back
        // over the release: a remembered `ownedRunning` for a process that is gone.
        await runner.set("ip", .init(stdout: ["192.168.64.7"], delay: .milliseconds(2_600)))
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner, recordedIdentities: [identity])
        let prepared = Task { try await lifecycle.prepare() }
        try await Task.sleep(for: .milliseconds(150))
        survivor.terminate(gracePeriod: .milliseconds(100))
        _ = await survivor.exit()
        try await prepared.value
        await runner.set("ip", .init(stdout: ["192.168.64.7"]))
        // Something else may hold that VM name now, so the stop is refused rather than sending
        // `tart stop` at a machine Guesthouse can no longer prove is its own.
        await #expect(throws: GuesthouseError.vmOwnershipUncertain(environment)) {
            _ = try await lifecycle.stop(environment, mode: .force) { _ in }
        }
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "stop" }))
    }

    @Test func aVMStartedAfterTheStopPreflightIsNotReportedAsStopped() async throws {
        let runner = tartLikeRunner(running: false)
        await runner.set("list", .init(stdout: [listJSON(running: false)], delay: .milliseconds(250)))
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .seconds(5))) { event in events.add(event) }
        // Between the preflight's observation and the journalled task, something starts the VM.
        await runner.set("list", .init(stdout: [listJSON(running: true)], delay: .milliseconds(250)))
        let seen = await collect(events, deadline: .seconds(10))
        #expect(seen.last == .failed(stop, .vmOwnershipUncertain(environment)), "a stop never completes over a VM that is running again")
        #expect(try await store.replay().inFlight.isEmpty)
    }

    @Test func aForceStopWithNothingLeftToSignalDoesNotAskTartToStopAStoppedVM() async throws {
        let runner = tartLikeRunner(running: false)
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let development = try #require(try await lifecycle.environments().first)
        // The supervised process ended between the ownership preflight and this step, so the
        // requested state is already reached; `tart stop` would answer `notRunning` and that
        // would be reported as a failed stop.
        try await lifecycle.endUnsupervisedVM(development, operation: OperationID())
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "stop" }))
    }

    @Test func theGracefulStopDeadlineCoversBothTheCommandAndTheProcessWait() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        // `tart stop` uses most of the deadline and the VM process never ends, so the wait for
        // it gets what is left rather than a fresh deadline of its own.
        await runner.set("stop", .init(delay: .milliseconds(800)))
        let events = EventCollector()
        let began = ContinuousClock.now
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .seconds(1))) { event in events.add(event) }
        let seen = await collect(events, deadline: .seconds(10))
        let elapsed = ContinuousClock.now - began
        #expect(seen.last == .failed(stop, .operationOutcomeUnknown(stop)))
        #expect(elapsed < .milliseconds(1_500), "one deadline covers the command and the wait, not one each (took \(elapsed))")
        await runner.finishHanging()
    }

    @Test func aHangingStatusRefreshDoesNotHoldTheTerminalEvent() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)
        // The inventory stops answering. The stop itself still completes and is durable, so the
        // client must not be left believing the operation is in flight.
        await runner.set("list", .init(hangs: true))
        let events = EventCollector()
        let began = ContinuousClock.now
        let stop = try await lifecycle.stop(environment, mode: .force) { event in events.add(event) }
        let seen = await collect(events, deadline: .seconds(20))
        let elapsed = ContinuousClock.now - began
        #expect(seen.last == .completed(stop))
        #expect(elapsed < .seconds(10), "the courtesy status is bounded (took \(elapsed))")
        #expect(try await store.replay().inFlight.isEmpty)
        await runner.finishHanging()
    }

    @Test func aHangingStatusRefreshDoesNotHoldTheStartsTerminalEvent() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let began = ContinuousClock.now
        let start = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in events.add(event) }
        // The address is found, the completed record is durable, and then the inventory hangs.
        await runner.set("list", .init(hangs: true))
        let seen = await collect(events, deadline: .seconds(20))
        let elapsed = ContinuousClock.now - began
        #expect(seen.last == .completed(start))
        #expect(elapsed < .seconds(10), "the courtesy status is bounded (took \(elapsed))")
        await runner.finishHanging()
    }

    @Test func aCancellationBeforeTheFirstProgressReportIsDeferred() async throws {
        let runner = tartLikeRunner()
        // The start's inventory read is slow, so the operation exists while no phase has been
        // reported for it and its task has not been created: the window a cancellation must be
        // held over rather than dropped or delivered into a protected phase.
        await runner.set("list", .init(stdout: [listJSON(running: false)], delay: .milliseconds(500)))
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let started = Task { try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(5))) { event in events.add(event) } }
        var pending: OperationID?
        for _ in 0..<200 where pending == nil {
            pending = await lifecycle.inFlightOperationID
            if pending == nil { try await Task.sleep(for: .milliseconds(2)) }
        }
        let operation = try #require(pending)
        #expect(await lifecycle.inFlightPhase == nil, "no phase has been reported for it yet")
        await lifecycle.cancel(operation)
        #expect(try await started.value == operation)
        let seen = await collect(events, deadline: .seconds(10))
        #expect(seen.contains(.progress(operation, ProgressPhase(kind: .startingVM, cancelable: false))), "the protected phase still ran")
        #expect(seen.last == .failed(operation, .canceled), "the deferred request was applied at the first cancelable phase")
        await runner.finishHanging()
    }

    @Test func aCanceledOperationStaysUnresolvedUntilInspectionSettlesIt() async throws {
        let runner = tartLikeRunner()
        await runner.set("ip", .init(hangs: true))
        let (lifecycle, store, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        let start = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(30))) { event in events.add(event) }
        for _ in 0..<400 where events.events.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await lifecycle.cancel(start)
        let seen = await collect(events, deadline: .seconds(10))
        #expect(seen.last == .failed(start, .canceled))
        #expect(try await store.replay().inFlight[start] != nil, "the journal reads a cancellation as still in flight")
        // Inspection is what settles it. Without the environment being tracked as unresolved,
        // nothing would reconcile and only a restart would rediscover the journal entry.
        _ = try await lifecycle.status(of: environment)
        #expect(try await store.replay().inFlight.isEmpty, "inspecting the actual state settles the canceled start")
        await runner.finishHanging()
    }

    @Test func aRuntimeThatCannotBeLaunchedAsksForRuntimeRepair() async throws {
        let (storage, store) = try makeStorage()
        try await seedSnapshot(in: store)
        // The bundle's executable is missing, so no process can be started at all.
        let bundle = TartBundle(url: storage.url(for: .runtime).appending(path: "tart.app"))
        let supervisor = OperationSupervisor(store: try ProcessIdentityStore(directory: storage.url(for: .state)))
        let lifecycle = EnvironmentLifecycle(dependencies: .init(backend: TartBackend(bundle: bundle, storage: storage, runner: ProcessRunner()), supervisor: supervisor, store: store))
        try await lifecycle.prepare()
        do {
            _ = try await lifecycle.status(of: environment)
            Issue.record("expected the runtime failure to be reported")
        } catch let error as GuesthouseError {
            #expect(error.caseName == "runtimeMissing", "reinstalling the runtime is what helps, not inspecting saved state")
            #expect(error.recoveryActions.contains(.repair(.runtime)))
        }
    }

    @Test func aReplacedRuntimeAsksForRuntimeRepairNotTheGuestNetwork() async throws {
        let (storage, store) = try makeStorage()
        try await seedSnapshot(in: store)
        let bundle = TartBundle(url: storage.url(for: .runtime).appending(path: "tart.app"))
        try FileManager.default.createDirectory(at: bundle.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bundle.executable, withDestinationURL: try TestHelper.executable())
        // The identity recorded at verification is not the bundle that is there now.
        let staleFile = TartBundle.FileIdentity(device: 1, inode: 2, size: 3, modified: timespec(tv_sec: 4, tv_nsec: 5), changed: timespec(tv_sec: 6, tv_nsec: 7))
        let stale = TartBundle.BundleIdentity(directoryDevice: 1, directoryInode: 2, infoPlist: staleFile, executable: staleFile)
        let backend = TartBackend(bundle: bundle, storage: storage, runner: tartLikeRunner(), verifiedBundle: stale)
        await #expect(throws: TartInvocationError.runtimeReplaced) { _ = try await backend.list() }
        let supervisor = OperationSupervisor(store: try ProcessIdentityStore(directory: storage.url(for: .state)))
        let lifecycle = EnvironmentLifecycle(dependencies: .init(backend: backend, supervisor: supervisor, store: store))
        try await lifecycle.prepare()
        do {
            _ = try await lifecycle.status(of: environment)
            Issue.record("expected the refusal to run a replaced runtime to be reported")
        } catch let error as GuesthouseError {
            #expect(error.caseName == "runtimeVerificationFailed", "Guesthouse refused to run the host runtime; no guest was probed")
            #expect(error.recoveryActions.contains(.repair(.runtime)))
        }
        #expect(EnvironmentLifecycle.map(.runtimeReplaced, environment: environment).caseName == "runtimeVerificationFailed")
    }

    @Test func aHangingAddressLookupEndsWithinTheRequestedWait() async throws {
        let (storage, store) = try makeStorage()
        let runner = tartLikeRunner()
        await runner.set("ip", .init(hangs: true))
        _ = try await makeLifecycle(runner: runner, storage: storage, store: store)
        let backend = TartBackend(bundle: TartBundle(url: storage.url(for: .runtime).appending(path: "tart.app")), storage: storage, runner: runner)
        let began = ContinuousClock.now
        await #expect(throws: TartInvocationError.timedOut) { _ = try await backend.ip(vmName: environment.tartVMName, wait: .seconds(2)) }
        let waited = ContinuousClock.now - began
        #expect(waited < .seconds(5), "the wait the caller asked for bounds the whole invocation (took \(waited))")
        // The probe every status inspection makes asks for no guest wait at all.
        let probeBegan = ContinuousClock.now
        await #expect(throws: TartInvocationError.timedOut) { _ = try await backend.ip(vmName: environment.tartVMName, wait: .zero) }
        let probed = ContinuousClock.now - probeBegan
        #expect(probed < .seconds(5), "a zero-wait probe no longer costs twenty seconds (took \(probed))")
        await runner.finishHanging()
    }

    /// Adoption manages local bundles alone, so a pulled image that happens to carry the
    /// environment's name is not the bundle it was registered with. Matching on the name alone
    /// would journal and launch a start against something Tart may go and fetch.
    @Test func anOCIImageCarryingTheVMsNameIsNotTheRegisteredBundle() async throws {
        let image = #"[{"Source":"OCI","Name":"\#(environment.tartVMName)","Disk":160,"Size":20,"Accessed":"2026-09-03T00:00:00Z","Running":false,"State":"stopped"}]"#
        let runner = FakeProcessRunner(script: ["list": .init(stdout: [image]), "run": .init(hangs: true), "ip": .init(stdout: ["192.168.64.7"]), "stop": .init()])
        let (storage, store) = try makeStorage()
        // Registered while the local bundle existed; it has since been removed from the store.
        try await seedSnapshot(in: store)
        let lifecycle = try await makeLifecycle(runner: runner, storage: storage, store: store)
        try await lifecycle.prepare()
        #expect(try await lifecycle.status(of: environment).vm == .notFound)
        await #expect(throws: GuesthouseError.environmentNotFound(environment)) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
        #expect(try await store.replay().inFlight.isEmpty, "a start with no bundle to run is refused before it is journaled")
        #expect(!(await runner.invocations.map(\.arguments).contains { $0.first == "run" }))
    }

    /// The field promises an address a guest connection can be made to. A VM observed as no
    /// longer running still has the address its supervised entry cached until the exit watcher
    /// runs, and answering with that would point SSH and Screen Sharing at an endpoint this VM
    /// no longer owns.
    @Test func anAddressIsReportedOnlyForAVMThatIsRunning() async throws {
        let real = LiveProcessEnumerator()
        let unreadable = Mutex(false)
        let enumerator = LiveProcessEnumerator(kernel: .init(
            pids: real.kernel.pids,
            arguments: { pid in unreadable.withLock { $0 } ? nil : real.kernel.arguments(pid) }
        ))
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner, enumerator: enumerator)
        try await lifecycle.prepare()
        let events = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(3))) { event in events.add(event) }
        _ = await collect(events)
        #expect(try await lifecycle.status(of: environment).guestAddress?.rawValue == "192.168.64.7")
        // The process table stops answering for the recorded process, which is the state a
        // supervised VM that ended leaves behind until its exit is observed.
        unreadable.withLock { $0 = true }
        let status = try await lifecycle.status(of: environment)
        #expect(status.vm != .running)
        #expect(status.guestAddress == nil, "an address the VM may no longer own is not reported")
        unreadable.withLock { $0 = false }
        _ = try await lifecycle.stop(environment, mode: .force) { _ in }
        try await waitUntilNotRunning(lifecycle)
    }

    /// The inventory proves the runtime, and the address probe then runs it again. A runtime
    /// removed in between is a host failure with a repair, and reporting it as a guest that
    /// cannot be reached would offer retry and guest inspection instead.
    @Test func aRuntimeLostUnderTheAddressProbeAsksForRepairNotForTheGuest() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in events.add(event) }
        _ = await collect(events)
        #expect(try await lifecycle.status(of: environment).guestAddress?.rawValue == "192.168.64.7")
        await runner.set("ip", .init(failsToLaunch: true))
        await #expect(throws: GuesthouseError.runtimeMissing) { _ = try await lifecycle.status(of: environment) }
        await runner.set("ip", .init(stdout: ["192.168.64.7"]))
        _ = try await lifecycle.stop(environment, mode: .force) { _ in }
        try await waitUntilNotRunning(lifecycle)
    }

    /// `tart stop` reaching its deadline spends the whole budget the caller gave. Establishing
    /// what happened may need `tart list`, whose own timeout is longer than the graceful stop
    /// itself, so that read is bounded: a Quit reports an outcome it will settle by inspection
    /// rather than sitting tens of seconds past what the user asked for.
    @Test func aStopWhoseDeadlinePassedDoesNotWaitOutAnUnboundedInventory() async throws {
        let real = LiveProcessEnumerator()
        let gone = Mutex(false)
        // The recorded process reads back as another program's, which is what the kernel
        // reports once the VM's own process has exited and its PID has been taken over: an
        // exit, not an unreadable process, so the observation falls through to the inventory.
        let enumerator = LiveProcessEnumerator(kernel: .init(
            pids: real.kernel.pids,
            arguments: { pid in gone.withLock { $0 } ? ["sleep", "600"] : real.kernel.arguments(pid) }
        ))
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner, enumerator: enumerator)
        try await lifecycle.prepare()
        let startEvents = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(ipWait: .seconds(1))) { event in startEvents.add(event) }
        _ = await collect(startEvents)

        await runner.set("stop", .init(hangs: true))
        let stopEvents = EventCollector()
        let stop = try await lifecycle.stop(environment, mode: .graceful(deadline: .seconds(1))) { event in stopEvents.add(event) }
        // Once the task's own ownership check has passed, the VM's process leaves the table
        // and the inventory stops answering promptly: this is the state that sends the
        // post-timeout observation to `tart list`.
        try await Task.sleep(for: .milliseconds(300))
        gone.withLock { $0 = true }
        await runner.set("list", .init(stdout: [listJSON(running: false, extra: ["ubuntu"])], delay: .seconds(8)))
        let began = ContinuousClock.now
        let seen = await collect(stopEvents, deadline: .seconds(15))
        #expect(seen.last == .failed(stop, .operationOutcomeUnknown(stop)), "an inventory that will not answer in the courtesy window leaves the outcome unknown")
        #expect(began.duration(to: .now) < .seconds(6), "the observation gave up long before the inventory's own timeout")
        gone.withLock { $0 = false }
        await runner.set("list", .init(stdout: [listJSON(running: false, extra: ["ubuntu"])]))
        await runner.finishHanging()
    }

    /// `StateStore.begin` makes the `started` record durable before the journal's own directory
    /// entry, so a failure at that second step throws over a record a later read in this same
    /// service still sees. Nothing had run when it failed, so a record that did land is closed
    /// rather than left in flight with nothing tracking it.
    @Test func aJournalBeginThatMayHaveLandedIsSettledRatherThanLeftInFlight() async throws {
        let runner = tartLikeRunner()
        let (storage, store) = try makeStorage()
        let lifecycle = try await makeLifecycle(runner: runner, storage: storage, store: store)
        try await lifecycle.prepare()
        // The record an indeterminate `begin` left behind.
        let operation = try await store.begin(.startEnvironment, for: environment)
        await lifecycle.reconcileIndeterminateBegin(operation, kind: .startEnvironment, environment: environment)
        let replay = try await store.replay()
        #expect(replay.inFlight.isEmpty, "the record that landed is closed as the mutation that never took effect")
        #expect(replay.records.last?.outcome == .notApplied)
        #expect(try await lifecycle.status(of: environment).readiness == .ready)

        // A journal that cannot be read leaves the same unknown, and the environment has to
        // carry it rather than report a readiness that would license a blind retry.
        let second = try await store.begin(.stopEnvironment, for: environment)
        let original = try breakJournal(in: storage)
        await lifecycle.reconcileIndeterminateBegin(second, kind: .stopEnvironment, environment: environment)
        #expect(try await lifecycle.status(of: environment).readiness == .needsAttention(.operationOutcomeUnknown(second)))
        try repairJournal(in: storage, with: original)
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
