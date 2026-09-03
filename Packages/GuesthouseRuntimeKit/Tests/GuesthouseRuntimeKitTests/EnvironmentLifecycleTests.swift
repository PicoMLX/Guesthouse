import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.serialized) struct EnvironmentLifecycleTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "LifecycleTests-\(UUID().uuidString)")
    let environment = EnvironmentID()

    func listJSON(running: Bool, extra: [String] = []) -> String {
        var entries = [#"{"Source":"local","Name":"\#(environment.tartVMName)","Disk":160,"Size":20,"Accessed":"2026-09-03T00:00:00Z","Running":\#(running),"State":"\#(running ? "running" : "stopped")"}"#]
        entries += extra.map { #"{"Source":"local","Name":"\#($0)","Disk":1,"Size":1,"Accessed":"2026-09-03T00:00:00Z","Running":false,"State":"stopped"}"# }
        return "[" + entries.joined(separator: ",") + "]"
    }

    func makeLifecycle(runner: FakeProcessRunner, recordedIdentities: [ProcessIdentity] = []) async throws -> (EnvironmentLifecycle, StateStore, RuntimeStorage) {
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let store = try StateStore(rootURL: storage.url(for: .state))
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
        let lifecycle = EnvironmentLifecycle(dependencies: .init(backend: TartBackend(bundle: bundle, storage: storage, runner: runner), supervisor: supervisor, store: store))
        return (lifecycle, store, storage)
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
    }

    @Test func nativeConsoleOmitsNoGraphics() async throws {
        let runner = tartLikeRunner()
        let (lifecycle, _, _) = try await makeLifecycle(runner: runner)
        try await lifecycle.prepare()
        let events = EventCollector()
        _ = try await lifecycle.start(environment, options: StartOptions(console: .native, ipWait: .seconds(1))) { event in events.add(event) }
        _ = await collect(events)
        #expect(await runner.invocations.map(\.arguments).contains(["run", environment.tartVMName]))
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
