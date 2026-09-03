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
        #expect(await runner.invocations.map(\.arguments).contains(["stop", environment.tartVMName, "--timeout", "20"]))
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
        guard case .needsAttention(let error) = status.readiness, error.caseName == "operationOutcomeUnknown" else { Issue.record("expected needsAttention"); return }
        await #expect(throws: GuesthouseError.self) {
            _ = try await lifecycle.start(environment, options: StartOptions()) { _ in }
        }
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
