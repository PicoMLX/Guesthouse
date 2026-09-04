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
    }

    private struct InFlight {
        let id: OperationID
        let environment: EnvironmentID
        /// `nil` while the slot is reserved but the operation has not been journaled yet.
        var task: Task<Void, Never>?
        /// The phase last reported; cancellation is deferred while it is not cancelable.
        var phase: ProgressPhase?
        var cancelRequested = false
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
        // An inventory that cannot be read adopts nothing, and is not a reason to fail the
        // launch: reconciliation marks the saved environments uncertain and inspection reads
        // the inventory again, whereas a throw here leaves the service permanently failed and
        // unable to answer even a status request (MVP-PLAN.md §4).
        guard let inventory = try? await deps.backend.list() else { return }
        let known = Set(snapshot.environments.map(\.id))
        var changed = false
        for vm in inventory where vm.source == .local {
            guard let id = Self.managedEnvironment(named: vm.name), !known.contains(id) else { continue }
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

    /// The environment a `guesthouse-<uuid>` VM name identifies, or `nil` for a VM this app
    /// does not manage. The name must round-trip, so a look-alike is never taken for ours.
    static func managedEnvironment(named name: String) -> EnvironmentID? {
        guard name.hasPrefix("guesthouse-"),
              let uuid = UUID(uuidString: String(name.dropFirst("guesthouse-".count)))
        else { return nil }
        let id = EnvironmentID(uuid: uuid)
        return id.tartVMName == name ? id : nil
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
                do {
                    try await deps.supervisor.forget(id)
                    verdicts[id] = nil
                    await settleInterruptedOperation(id)
                } catch {
                    // The record outlives the process it describes; until it can be removed
                    // the environment is uncertain rather than free.
                    verdicts[id] = .uncertain(.identityNotForgotten)
                }
            case .ownedRunning(let live):
                await adoptSurvivor(id, live: live)
                // A running VM settles an interrupted start. It does not settle an interrupted
                // stop: the `tart stop` an interrupted service left behind, and the guest
                // shutdown it asked for, can still finish afterwards, so that operation's
                // outcome is not established by this observation (MVP-PLAN.md §3).
                if unresolved[id]?.operation != .stopEnvironment {
                    await settleInterruptedOperation(id)
                }
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
        guard let record = unresolved[id] else { return }
        do {
            try await deps.store.append(JournalRecord(id: record.id, environmentID: id, operation: record.operation, timestamp: Date(), outcome: .reconciled))
            unresolved[id] = nil
        } catch {
            // The durable journal still says the mutation is in flight. Forgetting it here
            // would report the environment as settled while storage contradicts that, and
            // nothing short of a restart could clear it; the entry is kept so the next
            // inspection settles it once the journal is writable again.
        }
    }

    /// A process proven ours after a relaunch is supervised again: a transaction is held and
    /// its exit is watched, so the service does not idle out with the VM running.
    private func adoptSurvivor(_ id: EnvironmentID, live: LiveProcess) async {
        guard supervised[id] == nil, let identity = await deps.supervisor.identity(for: id) else { return }
        let token = deps.supervisor.hold("vm \(identity.vmName) (adopted)")
        supervised[id] = Supervised(run: nil, pid: live.pid, token: token, identity: identity, address: nil)
        watchExit(identity: identity, environment: id)
        // A recovered VM is only usable with its address; it is looked up now and again on
        // every status read until it is known.
        if let address = try? await deps.backend.ip(vmName: identity.vmName, wait: .seconds(1)) {
            supervised[id]?.address = address
        }
    }

    /// Asked of the kernel each time, and matched against the recorded identity, so a PID
    /// reused after the process died is never taken for the VM.
    private func isAlive(_ live: Supervised) -> Bool {
        deps.supervisor.verify(live.identity) != nil
    }

    // MARK: - Queries

    public func environments() -> [DevelopmentEnvironment] {
        snapshot.environments
    }

    public func status(of id: EnvironmentID) async throws -> EnvironmentStatus {
        guard let environment = snapshot.environments.first(where: { $0.id == id }) else {
            throw GuesthouseError.environmentNotFound(id)
        }
        // Inspection is how an uncertain verdict and an unsettled operation clear: the process
        // table and inventory are read again now, so neither an inventory that was unreadable
        // at launch nor a terminal record that could not be written blocks the environment
        // until the service restarts.
        let uncertain: Bool = if case .uncertain? = verdicts[id] { true } else { false }
        if inFlight == nil, uncertain || unresolved[id] != nil {
            await reconcile()
        }
        let inventory = try await self.inventory()
        let vm: EnvironmentStatus.VMState
        var readiness: EnvironmentStatus.Readiness
        if let live = supervised[id], isAlive(live) {
            vm = .running
            // Asked again on every inspection rather than cached once: Tart's NAT address can
            // change while the same VM process lives, most visibly after the host sleeps, and
            // a stale address sends SSH and Screen Sharing to the wrong endpoint (§4).
            supervised[id]?.address = try? await deps.backend.ip(vmName: environment.tartVMName, wait: .seconds(0))
            // Running without a confirmed address is not ready: nothing guest-dependent works.
            readiness = supervised[id]?.address != nil ? .ready : .needsAttention(.guestNotReachable(id))
        } else if case .uncertain(let reason)? = verdicts[id] {
            vm = .uncertain(reason: SanitizedText(Self.describe(reason), limit: 200))
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
        // A preserved slot is reported as such, so the GUI does not offer a start the
        // lifecycle would refuse.
        if snapshot.slots.state(of: id) == .preserved {
            readiness = .needsAttention(.environmentPreserved(id))
        }
        // An operation whose outcome is unknown outranks preservation: it is what has to be
        // inspected first, and it is what `refuseIfBlocked` will refuse a repair over (§3).
        if let record = unresolved[id] {
            readiness = .needsAttention(.operationOutcomeUnknown(record.id))
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
            let inventory = try await self.inventory()
            if let info = inventory.first(where: { $0.name == environment.tartVMName }), info.running {
                throw GuesthouseError.environmentAlreadyRunning(id)
            }
            // Every running app-managed VM counts against the one-running-VM invariant,
            // including a `guesthouse-<uuid>` the snapshot does not know: adoption may have
            // found no free slot for it, but it is still one of ours and still running (§4).
            if let other = inventory.filter(\.running).compactMap({ Self.managedEnvironment(named: $0.name) }).first(where: { $0 != id }) {
                throw GuesthouseError.anotherEnvironmentRunning(other)
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
            report(operation, ProgressPhase(kind: .startingVM, cancelable: false), events)
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
            // Watched before anything else can fail: a checkpoint that cannot be written
            // fails the operation, but the process is supervised either way.
            watchExit(of: run, environment: id)
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .startEnvironment, timestamp: Date(), outcome: .checkpoint(.runtimeReady)))

            report(operation, ProgressPhase(kind: .waitingForNetwork), events)
            let address = try await deps.backend.ip(vmName: environment.tartVMName, wait: options.ipWait)
            // An address says nothing if the process that was to own it is gone: a VM that
            // exited while the lookup was suspended was released by its exit watcher, and a
            // start that ends with no running VM has not completed.
            guard supervised[id]?.pid == run.processIdentifier else {
                throw GuesthouseError.guestNotReachable(id)
            }
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
        } catch is ProcessLaunchError {
            // The runtime program itself could not be started. Guesthouse's saved state is not
            // involved, and reinstalling the runtime — not inspecting state — is what helps.
            await fail(operation, kind: .startEnvironment, environment: id, with: .runtimeMissing, events: events)
        } catch {
            await fail(operation, kind: .startEnvironment, environment: id, with: .runtimeStateUnavailable(reason: SanitizedText(Self.describe(error), limit: 200)), events: events)
        }
    }

    /// Graceful stop through Tart, or the explicitly warned force-stop. Either way the VM must
    /// be proven ours: a supervised process or an owned reconciliation verdict, or an
    /// inventory that says nothing by that name is running.
    public func stop(_ id: EnvironmentID, mode: StopMode, events: @escaping EventSink) async throws -> OperationID {
        guard let environment = snapshot.environments.first(where: { $0.id == id }) else { throw GuesthouseError.environmentNotFound(id) }
        try refuseIfBlocked(id)
        let operation = OperationID()
        // The slot is taken before the first suspension, so two stops cannot both pass the
        // ownership check and signal the same VM.
        inFlight = InFlight(id: operation, environment: id, task: nil)
        let alreadyStopped: Bool
        do {
            alreadyStopped = try await requireOwnershipToStop(environment)
            _ = try await deps.store.begin(.stopEnvironment, for: id, id: operation)
        } catch {
            inFlight = nil
            throw error
        }
        let token = deps.supervisor.hold("stopEnvironment \(operation)")
        inFlight?.task = Task { [weak self] () async -> Void in
            guard let self else { return }
            await self.performStop(operation, environment: environment, mode: mode, alreadyStopped: alreadyStopped, token: token, events: events)
        }
        return operation
    }

    /// Both modes act on the VM by name or by PID, so neither may run against a machine this
    /// service cannot prove it started: an app-named VM someone else launched since the last
    /// reconciliation has no verdict of its own, and a graceful `tart stop <name>` would shut
    /// it down all the same (MVP-PLAN.md §4).
    ///
    /// Returns whether the requested stopped state is already reached, which needs no signal:
    /// a guest that finished shutting down after a graceful timeout, but before the warned
    /// force-stop was confirmed, is not an ownership problem.
    private func requireOwnershipToStop(_ environment: DevelopmentEnvironment) async throws -> Bool {
        if let live = supervised[environment.id], isAlive(live) { return false }
        if isOwned(verdicts[environment.id]) { return false }
        switch await observe(environment) {
        case .stopped: return true
        case .running, .unknown: throw GuesthouseError.vmOwnershipUncertain(environment.id)
        }
    }

    private func performStop(_ operation: OperationID, environment: DevelopmentEnvironment, mode: StopMode, alreadyStopped: Bool, token: OperationSupervisor.Token, events: EventSink) async {
        defer { token.end(); inFlight = nil }
        let id = environment.id
        do {
            switch mode {
            case .graceful(let deadline):
                report(operation, ProgressPhase(kind: .stoppingVM, cancelable: false), events)
                if !alreadyStopped {
                    try await gracefulStop(operation, environment: environment, deadline: deadline)
                    // Tart's command has returned, but the process hosting the VM may still be
                    // unwinding, and Quit waits for both. The wait is bounded by the deadline
                    // the caller asked for: the run itself was launched with a year-long
                    // timeout, so an unbounded wait here would never end (MVP-PLAN.md §2).
                    guard await waitForVMProcess(of: id, within: deadline) else {
                        throw GuesthouseError.operationOutcomeUnknown(operation)
                    }
                }
            case .force:
                report(operation, ProgressPhase(kind: .forceStoppingVM, cancelable: false), events)
                if !alreadyStopped {
                    if let live = supervised[id], let run = live.run {
                        run.terminate(gracePeriod: .seconds(5))
                        _ = await run.exit()
                    } else if let live = supervised[id] {
                        // An adopted survivor has no run to end; its process is signaled directly.
                        try await terminateAdopted(live, operation: operation)
                    } else {
                        try await deps.backend.stop(vmName: environment.tartVMName, deadline: .seconds(10))
                    }
                }
            }
            if let failure = await release(id) {
                throw GuesthouseError.runtimeStateUnavailable(reason: SanitizedText(Self.describe(failure), limit: 200))
            }
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

    /// Asks Tart to shut the guest down, then establishes what actually happened.
    ///
    /// A deadline that expires ends the `tart stop` command while the guest may still be
    /// completing the shutdown it was already asked for, so nothing terminal is recorded from
    /// the timeout alone: a VM still running is the reported timeout, a VM that is gone is a
    /// stop that completed late, and a state that cannot be read leaves the outcome unknown
    /// rather than unblocking the environment for a retry or a force-stop (MVP-PLAN.md §3).
    private func gracefulStop(_ operation: OperationID, environment: DevelopmentEnvironment, deadline: Duration) async throws {
        do {
            try await deps.backend.stop(vmName: environment.tartVMName, deadline: deadline)
        } catch TartInvocationError.timedOut {
            switch await observe(environment) {
            case .running: throw GuesthouseError.gracefulStopTimedOut(environment.id)
            case .stopped: return
            case .unknown: throw GuesthouseError.operationOutcomeUnknown(operation)
            }
        } catch TartInvocationError.failed(.notRunning) {
            // Already stopped, or exited between the ownership check and the request: the
            // requested state is reached once the VM itself confirms it.
            switch await observe(environment) {
            case .stopped: return
            case .running: throw TartInvocationError.failed(.notRunning)
            case .unknown: throw GuesthouseError.operationOutcomeUnknown(operation)
            }
        }
    }

    /// Waits for the process hosting the VM to end, giving up at `deadline`. `false` means the
    /// wait expired with the process still there, which leaves the outcome unestablished.
    ///
    /// A run this service launched and a survivor adopted after a relaunch are waited for the
    /// same way — by asking the kernel about the recorded identity — so an adopted VM's Tart
    /// process is waited for too, and only a definite absence counts as an exit (§4).
    private func waitForVMProcess(of id: EnvironmentID, within deadline: Duration) async -> Bool {
        guard let live = supervised[id] else { return true }
        let identity = live.identity
        return await poll(until: deadline) { deps.supervisor.observe(identity) == .absent }
    }

    private func poll(until deadline: Duration, _ finished: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: deadline)
        while true {
            if finished() { return true }
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Whether the VM is running, answered from the supervised process first and the inventory
    /// otherwise. `unknown` when neither can say, which is never treated as "stopped".
    private enum VMObservation { case running, stopped, unknown }

    private func observe(_ environment: DevelopmentEnvironment) async -> VMObservation {
        if let live = supervised[environment.id] {
            switch deps.supervisor.observe(live.identity) {
            case .present: return .running
            case .unavailable: return .unknown
            case .absent: break
            }
        }
        guard let inventory = try? await deps.backend.list() else { return .unknown }
        return inventory.contains { $0.name == environment.tartVMName && $0.running } ? .running : .stopped
    }

    /// Cancels the in-flight operation if it is the one named. While the reported phase is
    /// not cancelable the request is deferred to the next phase that is; an operation whose
    /// remaining phases are all protected (a stop) runs to its end and reports its real
    /// outcome, so a second stop is never attempted over an unknown one.
    public func cancel(_ operation: OperationID) {
        guard let current = inFlight, current.id == operation else { return }
        if let phase = current.phase, !phase.cancelable {
            inFlight?.cancelRequested = true
            return
        }
        current.task?.cancel()
    }

    /// Reports a phase and honors a cancellation deferred by a protected phase before it.
    private func report(_ operation: OperationID, _ phase: ProgressPhase, _ events: EventSink) {
        inFlight?.phase = phase
        events(.progress(operation, phase))
        if phase.cancelable, inFlight?.cancelRequested == true {
            inFlight?.task?.cancel()
        }
    }

    /// Ends an adopted process with SIGTERM, then SIGKILL after five seconds.
    ///
    /// The identity is observed again before every signal, so a PID that changed hands is left
    /// alone and a process the kernel will not describe is never signaled. A process that
    /// cannot be read at the end is neither proven gone nor proven alive, so the stop reports
    /// an unknown outcome instead of a success it did not establish (§4).
    private func terminateAdopted(_ live: Supervised, operation: OperationID) async throws {
        if case .present = deps.supervisor.observe(live.identity) {
            kill(live.pid, SIGTERM)
            for _ in 0..<50 where deps.supervisor.observe(live.identity) != .absent {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        if case .present = deps.supervisor.observe(live.identity) {
            kill(live.pid, SIGKILL)
            for _ in 0..<50 where deps.supervisor.observe(live.identity) != .absent {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        switch deps.supervisor.observe(live.identity) {
        case .absent:
            return
        case .present:
            throw GuesthouseError.runtimeStateUnavailable(reason: SanitizedText("the virtual machine process did not end", limit: 200))
        case .unavailable:
            throw GuesthouseError.operationOutcomeUnknown(operation)
        }
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

    /// Polls an adopted process by identity, not by PID alone: once the PID no longer carries
    /// the recorded start time, executable, and arguments, the VM process is gone. Only a
    /// definite absence ends the watch — a process table that declines to describe the process
    /// is not evidence that it exited, and releasing here would abandon a running VM (§4).
    private func watchExit(identity: ProcessIdentity, environment: EnvironmentID) {
        let supervisor = deps.supervisor
        Task { [weak self] in
            while supervisor.observe(identity) != .absent {
                try? await Task.sleep(for: .seconds(2))
            }
            await self?.processExited(environment, pid: identity.pid)
        }
    }

    private func processExited(_ id: EnvironmentID, pid: Int32) async {
        guard let live = supervised[id], live.pid == pid else { return }
        await release(id)
    }

    /// Ends supervision of an environment, and returns the failure that kept its durable
    /// identity on disk, if any.
    ///
    /// The identity is removed before the in-memory state is cleared. A dead PID left in
    /// `processes.json` is reconciled against whatever reuses that PID after a relaunch, so an
    /// environment whose record could not be removed is left uncertain rather than free, and a
    /// caller reporting an operation's outcome must not call it completed (MVP-PLAN.md §4).
    @discardableResult
    private func release(_ id: EnvironmentID) async -> (any Error)? {
        var failure: (any Error)?
        do {
            try await deps.supervisor.forget(id)
        } catch {
            failure = error
        }
        if let live = supervised.removeValue(forKey: id) {
            live.token.end()
        }
        verdicts[id] = failure == nil ? nil : .uncertain(.identityNotForgotten)
        return failure
    }

    /// Journals the failure under the operation's own kind (the journal refuses a record whose
    /// kind differs from its `started` record), then reports it.
    private func fail(_ operation: OperationID, kind: JournalOperation, environment: EnvironmentID, with error: GuesthouseError, events: EventSink) async {
        do {
            try await deps.store.append(JournalRecord(id: operation, environmentID: environment, operation: kind, timestamp: Date(), outcome: .failed(error)))
            // A recorded outcome that is itself unknown settles nothing: the environment stays
            // blocked, and status keeps asking for inspection, until actual state says what
            // the mutation did. The journal agrees; `leavesInFlight` reads it the same way.
            if case .operationOutcomeUnknown = error {
                unresolved[environment] = JournalRecord(id: operation, environmentID: environment, operation: kind, timestamp: Date(), outcome: .started)
            }
        } catch {
            // The journal still says "in flight". Until the actual state is inspected the
            // environment stays blocked and the client is told the outcome is unknown, not
            // that the operation failed: an unrecorded result must not license a retry.
            unresolved[environment] = JournalRecord(id: operation, environmentID: environment, operation: kind, timestamp: Date(), outcome: .started)
            events(.failed(operation, .operationOutcomeUnknown(operation)))
            return
        }
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
        case .anotherProcessClaimsVM: "another process claims the virtual machine"
        case .recordInconsistent: "the recorded process names a different virtual machine"
        case .processUnobservable: "the recorded process exists but could not be read"
        case .vmNameUnconfirmed: "the running process does not name this virtual machine"
        case .identityNotForgotten: "the record of the virtual machine's process could not be removed"
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

    /// The VM inventory, with its failures named as inventory failures. `tart list` runs on
    /// the host and probes no guest network, so a hung or failing one is a runtime and state
    /// availability problem, never a guest that cannot be reached.
    private func inventory() async throws -> [TartVMInfo] {
        do {
            return try await deps.backend.list()
        } catch let error as TartInvocationError {
            throw Self.mapInventory(error)
        }
    }

    /// How an inventory command's failure reads to the user, as distinct from `map`, which
    /// answers for commands addressed at one VM.
    public static func mapInventory(_ error: TartInvocationError) -> GuesthouseError {
        switch error {
        case .unparseableOutput: .runtimeIncompatible(found: nil, required: TartPin.releaseTag)
        case .timedOut: .runtimeStateUnavailable(reason: SanitizedText("the list of virtual machines did not answer in time", limit: 200))
        case .failed: .runtimeStateUnavailable(reason: SanitizedText("the list of virtual machines could not be read", limit: 200))
        }
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
