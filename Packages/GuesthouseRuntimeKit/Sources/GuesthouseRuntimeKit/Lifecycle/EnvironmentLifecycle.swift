import Foundation
import GuesthouseCore

/// Start, stop, and status for the app-managed VMs, with one lifecycle operation in flight at
/// a time (MVP-PLAN.md §10, Phase 1). Every step is journaled before it is reported, every
/// running VM process is supervised with a held transaction, and a start is refused whenever
/// ownership of the VM is uncertain (§4).
public actor EnvironmentLifecycle {
    public typealias EventSink = @Sendable (RuntimeEvent) -> Void

    public struct Dependencies: Sendable {
        public var backend: TartBackend
        public var supervisor: OperationSupervisor
        public var store: StateStore

        public init(backend: TartBackend, supervisor: OperationSupervisor, store: StateStore) {
            self.backend = backend
            self.supervisor = supervisor
            self.store = store
        }
    }

    private struct Supervised {
        let run: ProcessRun
        let token: OperationSupervisor.Token
        let identity: ProcessIdentity
        var address: GuestIPAddress?
    }

    private struct InFlight {
        let id: OperationID
        let environment: EnvironmentID
        let task: Task<Void, Never>
    }

    private let deps: Dependencies
    private var snapshot: EnvironmentsSnapshot = .empty
    private var supervised: [EnvironmentID: Supervised] = [:]
    private var verdicts: [EnvironmentID: OwnershipVerdict] = [:]
    private var inFlight: InFlight?
    private var reconciledAt: Date?

    public init(dependencies: Dependencies) {
        deps = dependencies
    }

    // MARK: - Launch

    /// Loads state, adopts app-managed VMs found in the store, and reconciles recorded
    /// processes. Call once when the service starts.
    public func prepare() async throws {
        snapshot = try await deps.store.loadSnapshot()
        try await adoptExistingVMs()
        await reconcile()
    }

    /// Any VM in `TART_HOME` named `guesthouse-<uuid>` that the snapshot does not know is
    /// adopted into a free slot. This is how a VM created by hand for phase 0 becomes an
    /// environment; nothing is created here.
    public func adoptExistingVMs() async throws {
        let known = Set(snapshot.environments.map(\.id))
        var changed = false
        for vm in try await deps.backend.list() where vm.source == .local {
            guard vm.name.hasPrefix("guesthouse-"), let uuid = UUID(uuidString: String(vm.name.dropFirst("guesthouse-".count))) else { continue }
            let id = EnvironmentID(uuid: uuid)
            guard id.tartVMName == vm.name, !known.contains(id) else { continue }
            do {
                try snapshot.slots.reserve(id)
            } catch {
                continue
            }
            snapshot.environments.append(DevelopmentEnvironment(id: id, name: vm.name, createdAt: Date()))
            changed = true
        }
        if changed { try await deps.store.saveSnapshot(snapshot) }
    }

    /// Re-derives ownership of every recorded process from the live process table and the
    /// VM inventory. An `uncertain` verdict blocks `start` until a repair clears it.
    public func reconcile() async {
        let running = Set((try? await deps.backend.list())?.filter(\.running).map(\.name) ?? [])
        let byEnvironment = Dictionary(uniqueKeysWithValues: snapshot.environments.map { ($0.id, $0) })
        verdicts = await deps.supervisor.reconcile { id in
            byEnvironment[id].map { running.contains($0.tartVMName) }
        }
        reconciledAt = Date()
    }

    // MARK: - Queries

    public func environments() -> [DevelopmentEnvironment] {
        snapshot.environments
    }

    public func status(of id: EnvironmentID) async throws -> EnvironmentStatus {
        guard let environment = snapshot.environments.first(where: { $0.id == id }) else {
            throw GuesthouseError.environmentNotFound(id)
        }
        let inventory = try await deps.backend.list()
        let vm: EnvironmentStatus.VMState
        if let live = supervised[id], live.run.processIdentifier > 0, verdicts[id] == nil || isOwned(verdicts[id]) {
            vm = .running
        } else if case .uncertain(let reason)? = verdicts[id] {
            vm = .uncertain(reason: String(describing: reason))
        } else if let info = inventory.first(where: { $0.name == environment.tartVMName }) {
            vm = info.running ? .running : .stopped
        } else {
            vm = .notFound
        }
        let readiness: EnvironmentStatus.Readiness
        switch vm {
        case .uncertain: readiness = .needsAttention(.operationOutcomeUnknown(supervisedOperation(for: id) ?? OperationID()))
        case .notFound: readiness = .needsAttention(.environmentNotFound(id))
        case .running, .stopped: readiness = .ready
        }
        return EnvironmentStatus(
            environmentID: id,
            vm: vm,
            readiness: readiness,
            inFlightOperation: inFlight?.environment == id ? inFlight?.id : nil,
            guestAddress: supervised[id]?.address,
            reconciledAt: reconciledAt
        )
    }

    // MARK: - Operations

    /// Journals, launches, supervises, and waits for the guest's address. Returns the
    /// operation id once the journal has it and the launch is under way; progress and the
    /// result arrive through `events`.
    public func start(_ id: EnvironmentID, options: StartOptions, events: @escaping EventSink) async throws -> OperationID {
        guard let environment = snapshot.environments.first(where: { $0.id == id }) else { throw GuesthouseError.environmentNotFound(id) }
        if let inFlight { throw GuesthouseError.operationInFlight(inFlight.id) }
        if case .uncertain? = verdicts[id] { throw GuesthouseError.operationOutcomeUnknown(supervisedOperation(for: id) ?? OperationID()) }
        if supervised[id] != nil { throw GuesthouseError.environmentAlreadyRunning(id) }
        if let info = try await deps.backend.list().first(where: { $0.name == environment.tartVMName }), info.running {
            throw GuesthouseError.environmentAlreadyRunning(id)
        }

        let operation = try await deps.store.begin(.startEnvironment, for: id)
        let token = deps.supervisor.hold("startEnvironment \(operation)")
        let task = Task { [weak self] () async -> Void in
            guard let self else { return }
            await self.performStart(operation, environment: environment, options: options, token: token, events: events)
        }
        inFlight = InFlight(id: operation, environment: id, task: task)
        return operation
    }

    private func performStart(_ operation: OperationID, environment: DevelopmentEnvironment, options: StartOptions, token: OperationSupervisor.Token, events: EventSink) async {
        defer { token.end(); inFlight = nil }
        let id = environment.id
        do {
            events(.progress(operation, ProgressPhase(kind: .startingVM, cancelable: false)))
            let run = try await deps.backend.run(vmName: environment.tartVMName, console: options.console)
            let identity = try await deps.supervisor.recordLaunch(pid: run.processIdentifier, executable: deps.backend.bundle.executable, arguments: ["run", environment.tartVMName], vmName: environment.tartVMName, environment: id)
            let vmToken = deps.supervisor.hold("vm \(environment.tartVMName)")
            supervised[id] = Supervised(run: run, token: vmToken, identity: identity, address: nil)
            verdicts[id] = nil
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .startEnvironment, timestamp: Date(), outcome: .checkpoint(.runtimeReady)))
            watchExit(of: run, environment: id)

            events(.progress(operation, ProgressPhase(kind: .waitingForNetwork)))
            let address = try await deps.backend.ip(vmName: environment.tartVMName, wait: options.ipWait)
            supervised[id]?.address = address
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .startEnvironment, timestamp: Date(), outcome: .completed))
            events(.status(try await status(of: id)))
            events(.completed(operation))
        } catch is CancellationError {
            await fail(operation, kind: .startEnvironment, environment: id, with: .canceled, events: events)
        } catch let error as GuesthouseError {
            await fail(operation, kind: .startEnvironment, environment: id, with: error, events: events)
        } catch let error as TartInvocationError {
            await fail(operation, kind: .startEnvironment, environment: id, with: Self.map(error, environment: id), events: events)
        } catch {
            await fail(operation, kind: .startEnvironment, environment: id, with: .guestNotReachable(id), events: events)
        }
    }

    /// Graceful stop through Tart, then a warned force-stop only when the request says so.
    public func stop(_ id: EnvironmentID, mode: StopMode, events: @escaping EventSink) async throws -> OperationID {
        guard let environment = snapshot.environments.first(where: { $0.id == id }) else { throw GuesthouseError.environmentNotFound(id) }
        if let inFlight { throw GuesthouseError.operationInFlight(inFlight.id) }
        if case .uncertain? = verdicts[id] { throw GuesthouseError.operationOutcomeUnknown(supervisedOperation(for: id) ?? OperationID()) }
        let operation = try await deps.store.begin(.stopEnvironment, for: id)
        let token = deps.supervisor.hold("stopEnvironment \(operation)")
        let task = Task { [weak self] () async -> Void in
            guard let self else { return }
            await self.performStop(operation, environment: environment, mode: mode, token: token, events: events)
        }
        inFlight = InFlight(id: operation, environment: id, task: task)
        return operation
    }

    private func performStop(_ operation: OperationID, environment: DevelopmentEnvironment, mode: StopMode, token: OperationSupervisor.Token, events: EventSink) async {
        defer { token.end(); inFlight = nil }
        let id = environment.id
        do {
            switch mode {
            case .graceful(let deadline):
                events(.progress(operation, ProgressPhase(kind: .stoppingVM, cancelable: false)))
                try await deps.backend.stop(vmName: environment.tartVMName, deadline: deadline)
                if let live = supervised[id] {
                    _ = await live.run.exit()
                }
            case .force:
                events(.progress(operation, ProgressPhase(kind: .forceStoppingVM, cancelable: false)))
                if let live = supervised[id] {
                    live.run.terminate(gracePeriod: .seconds(5))
                    _ = await live.run.exit()
                } else {
                    try await deps.backend.stop(vmName: environment.tartVMName, deadline: .seconds(1))
                }
            }
            await release(id)
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .stopEnvironment, timestamp: Date(), outcome: .completed))
            events(.status(try await status(of: id)))
            events(.completed(operation))
        } catch is CancellationError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: .canceled, events: events)
        } catch let error as GuesthouseError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: error, events: events)
        } catch let error as TartInvocationError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: Self.map(error, environment: id), events: events)
        } catch {
            await fail(operation, kind: .stopEnvironment, environment: id, with: .guestNotReachable(id), events: events)
        }
    }

    /// Cancels the in-flight operation if it is the one named. Phases marked non-cancelable
    /// still run to their next checkpoint before the cancellation takes effect.
    public func cancel(_ operation: OperationID) {
        guard let inFlight, inFlight.id == operation else { return }
        inFlight.task.cancel()
    }

    // MARK: - Internals

    private func watchExit(of run: ProcessRun, environment: EnvironmentID) {
        Task { [weak self] in
            _ = await run.exit()
            await self?.processExited(environment, run: run)
        }
    }

    private func processExited(_ id: EnvironmentID, run: ProcessRun) async {
        guard let live = supervised[id], live.run === run else { return }
        await release(id)
    }

    private func release(_ id: EnvironmentID) async {
        if let live = supervised.removeValue(forKey: id) {
            live.token.end()
        }
        try? await deps.supervisor.forget(id)
        verdicts[id] = nil
    }

    /// Journals the failure under the operation's own kind (the journal refuses a record whose
    /// kind differs from its `started` record), then reports it.
    private func fail(_ operation: OperationID, kind: JournalOperation, environment: EnvironmentID, with error: GuesthouseError, events: EventSink) async {
        try? await deps.store.append(JournalRecord(id: operation, environmentID: environment, operation: kind, timestamp: Date(), outcome: .failed(error)))
        events(.failed(operation, error))
    }

    private func isOwned(_ verdict: OwnershipVerdict?) -> Bool {
        if case .ownedRunning? = verdict { return true }
        return false
    }

    private func supervisedOperation(for id: EnvironmentID) -> OperationID? {
        inFlight?.environment == id ? inFlight?.id : nil
    }

    static func map(_ error: TartInvocationError, environment: EnvironmentID) -> GuesthouseError {
        switch error {
        case .unparseableOutput: .toolMismatch(tool: "tart", found: nil, expected: TartPin.releaseTag)
        case .failed(let failure):
            switch failure {
            case .vmNotFound: .environmentNotFound(environment)
            case .alreadyRunning, .lockHeld: .environmentAlreadyRunning(environment)
            case .noIPAddress, .notRunning: .guestNotReachable(environment)
            case .virtualMachineLimitExceeded: .vmSlotUnavailable(maximum: VMSlotInventory.maximumSlots)
            case .requiresStoppedVM, .directoryAlreadyInitialized, .diskInUse, .unknown: .guestNotReachable(environment)
            }
        }
    }
}
