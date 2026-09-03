import Darwin
import Foundation
import GuesthouseCore

/// Start, stop, and status for the app-managed VMs, with one lifecycle operation and one
/// running VM at a time (MVP-PLAN.md §4, §6, §10 Phase 1). Every step is journaled before it
/// is reported, every running VM process is supervised with a held transaction, an
/// interrupted operation found in the journal at launch blocks its environment until the
/// actual state settles it, and nothing is started or stopped while ownership of the VM is
/// uncertain (§4).
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
        /// `nil` for a survivor adopted after a relaunch; its exit is polled instead.
        let run: ProcessRun?
        let pid: Int32
        let token: OperationSupervisor.Token
        let identity: ProcessIdentity
        var address: GuestIPAddress?

        /// Asked of the kernel, not inferred: a process that died a moment ago is not running.
        var isAlive: Bool { kill(pid, 0) == 0 }
    }

    private struct InFlight {
        let id: OperationID
        let environment: EnvironmentID
        /// `nil` while the slot is reserved but the operation has not been journaled yet.
        var task: Task<Void, Never>?
    }

    private let deps: Dependencies
    private var snapshot: EnvironmentsSnapshot = .empty
    private var supervised: [EnvironmentID: Supervised] = [:]
    private var verdicts: [EnvironmentID: OwnershipVerdict] = [:]
    /// Journal records an interrupted service left in flight, until the actual state settles them.
    private var unresolved: [EnvironmentID: JournalRecord] = [:]
    private var inFlight: InFlight?
    private var reconciledAt: Date?

    public init(dependencies: Dependencies) {
        deps = dependencies
    }

    // MARK: - Launch

    /// Loads state, adopts app-managed VMs found in the store, replays the journal, and
    /// reconciles recorded processes. Call once when the service starts.
    public func prepare() async throws {
        snapshot = try await deps.store.loadSnapshot()
        try await adoptExistingVMs()
        let replay = try await deps.store.replay()
        for record in replay.inFlight.values {
            unresolved[record.environmentID] = record
        }
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

    /// Re-derives ownership of every environment from the live process table and the VM
    /// inventory. A confirmed exit forgets the identity and settles an interrupted operation;
    /// an owned survivor is adopted back under supervision; an `uncertain` verdict blocks
    /// start and stop until a repair clears it. An unreadable inventory makes everything
    /// uncertain rather than assumed absent.
    public func reconcile() async {
        let inventory = try? await deps.backend.list()
        let running = Set(inventory?.filter(\.running).map(\.name) ?? [])
        let byEnvironment = Dictionary(uniqueKeysWithValues: snapshot.environments.map { ($0.id, $0) })
        var verdicts = await deps.supervisor.reconcile(environments: Array(byEnvironment.keys)) { id in
            guard inventory != nil else { return .unknown }
            guard let environment = byEnvironment[id] else { return .absent }
            return running.contains(environment.tartVMName) ? .present : .absent
        }
        for (id, verdict) in verdicts {
            switch verdict {
            case .exited:
                try? await deps.supervisor.forget(id)
                verdicts[id] = nil
                await settleInterruptedOperation(id)
            case .ownedRunning(let live):
                await adoptSurvivor(id, live: live)
                await settleInterruptedOperation(id)
            case .uncertain:
                break
            }
        }
        self.verdicts = verdicts
        if inventory != nil {
            for id in unresolved.keys where verdicts[id] == nil && supervised[id] == nil {
                await settleInterruptedOperation(id)
            }
        }
        reconciledAt = Date()
    }

    private func settleInterruptedOperation(_ id: EnvironmentID) async {
        guard let record = unresolved.removeValue(forKey: id) else { return }
        try? await deps.store.append(JournalRecord(id: record.id, environmentID: id, operation: record.operation, timestamp: Date(), outcome: .reconciled))
    }

    /// A process proven ours after a relaunch is supervised again: a transaction is held and
    /// its exit is watched, so the service does not idle out with the VM running.
    private func adoptSurvivor(_ id: EnvironmentID, live: LiveProcess) async {
        guard supervised[id] == nil, let identity = await deps.supervisor.identity(for: id) else { return }
        let token = deps.supervisor.hold("vm \(identity.vmName) (adopted)")
        supervised[id] = Supervised(run: nil, pid: live.pid, token: token, identity: identity, address: nil)
        watchExit(pid: live.pid, environment: id)
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
        var readiness: EnvironmentStatus.Readiness
        if let live = supervised[id], live.isAlive {
            vm = .running
            // Running without a confirmed address is not ready: nothing guest-dependent works.
            readiness = live.address != nil ? .ready : .needsAttention(.guestNotReachable(id))
        } else if case .uncertain(let reason)? = verdicts[id] {
            vm = .uncertain(reason: Self.describe(reason))
            readiness = .needsAttention(.vmOwnershipUncertain(id))
        } else if let info = inventory.first(where: { $0.name == environment.tartVMName }) {
            if info.running {
                // Running according to Tart with no supervised process and no owned verdict.
                vm = .uncertain(reason: "running without a recorded owner")
                readiness = .needsAttention(.vmOwnershipUncertain(id))
            } else {
                vm = .stopped
                readiness = .ready
            }
        } else {
            vm = .notFound
            readiness = .needsAttention(.environmentNotFound(id))
        }
        if let record = unresolved[id] {
            readiness = .needsAttention(.operationOutcomeUnknown(record.id))
        }
        // A preserved slot is reported as such, so the GUI does not offer a start the
        // lifecycle would refuse.
        if snapshot.slots.state(of: id) == .preserved {
            readiness = .needsAttention(.environmentPreserved(id))
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
        try refuseIfBlocked(id)
        guard snapshot.slots.state(of: id) == .active else { throw GuesthouseError.environmentPreserved(id) }
        if supervised[id] != nil { throw GuesthouseError.environmentAlreadyRunning(id) }
        if let other = supervised.keys.first(where: { $0 != id }) { throw GuesthouseError.anotherEnvironmentRunning(other) }

        // The slot is taken before the first suspension, so two simultaneous starts cannot
        // both pass the checks and launch two instances against one disk.
        let operation = OperationID()
        inFlight = InFlight(id: operation, environment: id, task: nil)
        do {
            let inventory = try await deps.backend.list()
            if let info = inventory.first(where: { $0.name == environment.tartVMName }), info.running {
                throw GuesthouseError.environmentAlreadyRunning(id)
            }
            let runningNames = Set(inventory.filter(\.running).map(\.name))
            if let other = snapshot.environments.first(where: { $0.id != id && runningNames.contains($0.tartVMName) }) {
                throw GuesthouseError.anotherEnvironmentRunning(other.id)
            }
            _ = try await deps.store.begin(.startEnvironment, for: id, id: operation)
        } catch {
            inFlight = nil
            throw error
        }
        let token = deps.supervisor.hold("startEnvironment \(operation)")
        inFlight?.task = Task { [weak self] () async -> Void in
            guard let self else { return }
            await self.performStart(operation, environment: environment, options: options, token: token, events: events)
        }
        return operation
    }

    private func performStart(_ operation: OperationID, environment: DevelopmentEnvironment, options: StartOptions, token: OperationSupervisor.Token, events: EventSink) async {
        defer { token.end(); inFlight = nil }
        let id = environment.id
        let arguments = TartBackend.runArguments(vmName: environment.tartVMName, console: options.console)
        do {
            events(.progress(operation, ProgressPhase(kind: .startingVM, cancelable: false)))
            let run = try await deps.backend.run(vmName: environment.tartVMName, console: options.console)
            drainOutput(of: run)
            let identity: ProcessIdentity
            do {
                identity = try await deps.supervisor.recordLaunch(pid: run.processIdentifier, executable: deps.backend.bundle.executable, arguments: arguments, vmName: environment.tartVMName, environment: id)
            } catch {
                // Without a durable identity the VM would be an orphan after a relaunch: it is
                // ended before the failure is reported.
                run.terminate(gracePeriod: .seconds(30))
                _ = await run.exit()
                throw GuesthouseError.runtimeStateUnavailable(reason: SanitizedText(Self.describe(error), limit: 200))
            }
            let vmToken = deps.supervisor.hold("vm \(environment.tartVMName)")
            supervised[id] = Supervised(run: run, pid: run.processIdentifier, token: vmToken, identity: identity, address: nil)
            verdicts[id] = nil
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .startEnvironment, timestamp: Date(), outcome: .checkpoint(.runtimeReady)))
            watchExit(of: run, environment: id)

            events(.progress(operation, ProgressPhase(kind: .waitingForNetwork)))
            let address = try await deps.backend.ip(vmName: environment.tartVMName, wait: options.ipWait)
            supervised[id]?.address = address
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .startEnvironment, timestamp: Date(), outcome: .completed))
            // The operation is complete whatever a best-effort status refresh does now.
            if let status = try? await status(of: id) { events(.status(status)) }
            events(.completed(operation))
        } catch is CancellationError {
            await fail(operation, kind: .startEnvironment, environment: id, with: .canceled, events: events)
        } catch let error as GuesthouseError {
            await fail(operation, kind: .startEnvironment, environment: id, with: error, events: events)
        } catch let error as TartInvocationError {
            await fail(operation, kind: .startEnvironment, environment: id, with: Self.map(error, environment: id), events: events)
        } catch {
            await fail(operation, kind: .startEnvironment, environment: id, with: .runtimeStateUnavailable(reason: SanitizedText(Self.describe(error), limit: 200)), events: events)
        }
    }

    /// Graceful stop through Tart, or the explicitly warned force-stop. Force-stopping needs
    /// ownership evidence: a supervised process or an owned reconciliation verdict.
    public func stop(_ id: EnvironmentID, mode: StopMode, events: @escaping EventSink) async throws -> OperationID {
        guard let environment = snapshot.environments.first(where: { $0.id == id }) else { throw GuesthouseError.environmentNotFound(id) }
        try refuseIfBlocked(id)
        if mode == .force, supervised[id] == nil, !isOwned(verdicts[id]) {
            throw GuesthouseError.vmOwnershipUncertain(id)
        }
        let operation = OperationID()
        inFlight = InFlight(id: operation, environment: id, task: nil)
        do {
            _ = try await deps.store.begin(.stopEnvironment, for: id, id: operation)
        } catch {
            inFlight = nil
            throw error
        }
        let token = deps.supervisor.hold("stopEnvironment \(operation)")
        inFlight?.task = Task { [weak self] () async -> Void in
            guard let self else { return }
            await self.performStop(operation, environment: environment, mode: mode, token: token, events: events)
        }
        return operation
    }

    private func performStop(_ operation: OperationID, environment: DevelopmentEnvironment, mode: StopMode, token: OperationSupervisor.Token, events: EventSink) async {
        defer { token.end(); inFlight = nil }
        let id = environment.id
        do {
            switch mode {
            case .graceful(let deadline):
                events(.progress(operation, ProgressPhase(kind: .stoppingVM, cancelable: false)))
                do {
                    try await deps.backend.stop(vmName: environment.tartVMName, deadline: deadline)
                } catch TartInvocationError.timedOut {
                    throw GuesthouseError.gracefulStopTimedOut(id)
                }
                if let live = supervised[id], let run = live.run {
                    _ = await run.exit()
                }
            case .force:
                events(.progress(operation, ProgressPhase(kind: .forceStoppingVM, cancelable: false)))
                if let live = supervised[id], let run = live.run {
                    run.terminate(gracePeriod: .seconds(5))
                    _ = await run.exit()
                } else {
                    try await deps.backend.stop(vmName: environment.tartVMName, deadline: .seconds(10))
                }
            }
            await release(id)
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .stopEnvironment, timestamp: Date(), outcome: .completed))
            if let status = try? await status(of: id) { events(.status(status)) }
            events(.completed(operation))
        } catch is CancellationError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: .canceled, events: events)
        } catch let error as GuesthouseError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: error, events: events)
        } catch let error as TartInvocationError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: Self.map(error, environment: id), events: events)
        } catch {
            await fail(operation, kind: .stopEnvironment, environment: id, with: .runtimeStateUnavailable(reason: SanitizedText(Self.describe(error), limit: 200)), events: events)
        }
    }

    /// Cancels the in-flight operation if it is the one named. Phases marked non-cancelable
    /// still run to their next checkpoint before the cancellation takes effect.
    public func cancel(_ operation: OperationID) {
        guard let inFlight, inFlight.id == operation else { return }
        inFlight.task?.cancel()
    }

    // MARK: - Internals

    /// The checks every operation shares: one at a time, no interrupted operation left
    /// unresolved, and no uncertain ownership.
    private func refuseIfBlocked(_ id: EnvironmentID) throws {
        if let inFlight { throw GuesthouseError.operationInFlight(inFlight.id) }
        if let record = unresolved[id] { throw GuesthouseError.operationOutcomeUnknown(record.id) }
        if case .uncertain? = verdicts[id] { throw GuesthouseError.vmOwnershipUncertain(id) }
    }

    /// Tart's output over a VM's lifetime is already redacted and is not kept: the stream is
    /// consumed so the bounded buffer never fills.
    private func drainOutput(of run: ProcessRun) {
        Task.detached {
            for await _ in run.output {}
        }
    }

    private func watchExit(of run: ProcessRun, environment: EnvironmentID) {
        Task { [weak self] in
            _ = await run.exit()
            await self?.processExited(environment, pid: run.processIdentifier)
        }
    }

    private func watchExit(pid: Int32, environment: EnvironmentID) {
        Task { [weak self] in
            while kill(pid, 0) == 0 {
                try? await Task.sleep(for: .seconds(2))
            }
            await self?.processExited(environment, pid: pid)
        }
    }

    private func processExited(_ id: EnvironmentID, pid: Int32) async {
        guard let live = supervised[id], live.pid == pid else { return }
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

    static func describe(_ reason: OwnershipVerdict.UncertaintyReason) -> String {
        switch reason {
        case .pidReusedByAnotherProcess: "the recorded process id now belongs to another process"
        case .executableMismatch: "the recorded process runs a different program"
        case .argumentsMismatch: "the recorded process runs with different arguments"
        case .lockHeldWithoutProcess: "the virtual machine is locked but no recorded process holds it"
        case .multipleCandidates: "more than one process matches the record"
        case .unrecordedLaunch: "the virtual machine is running but no launch was recorded"
        case .inventoryUnavailable: "the virtual machine inventory could not be read"
        }
    }

    /// Error text safe for a user-facing reason: the error's case name only.
    static func describe(_ error: any Error) -> String {
        if let error = error as? SupervisionError { return error.userMessage }
        if let error = error as? ProcessIdentityStoreError { return error.userMessage }
        if let error = error as? StateStoreError { return error.userMessage }
        let text = String(describing: error)
        return String(text.prefix { $0 != "(" && $0 != ":" })
    }

    public static func map(_ error: TartInvocationError, environment: EnvironmentID) -> GuesthouseError {
        switch error {
        case .unparseableOutput: .runtimeIncompatible(found: nil, required: TartPin.releaseTag)
        case .timedOut: .guestNotReachable(environment)
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
