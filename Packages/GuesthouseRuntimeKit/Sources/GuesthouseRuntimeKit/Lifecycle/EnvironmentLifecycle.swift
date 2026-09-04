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
    /// Set while an inventory failure has kept adoption from running, so a later listing tries
    /// again instead of hiding a hand-created VM for the rest of the service's life.
    private var adoptionPending = true

    /// How long a terminal event may wait for the courtesy status that precedes it. The
    /// operation is already durable by then, and a `tart list` that hangs must not keep the
    /// client believing the work is still in flight (MVP-PLAN.md §2).
    static let statusRefreshBudget = Duration.seconds(2)

    /// Where a VM process's output goes while an operation on its environment is in flight:
    /// the operation's own event stream, as `log` events. Between operations nobody listens
    /// and the lines are dropped, never buffered.
    private var outputSinks: [EnvironmentID: (operation: OperationID, events: EventSink)] = [:]
    /// The task forwarding each supervised process's output, so a failure can wait for the
    /// tail of that output before the sink goes away, and the environments whose output has
    /// not run out yet.
    private var drains: [EnvironmentID: Task<Void, Never>] = [:]
    private var draining: Set<EnvironmentID> = []

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
        guard let inventory = try? await deps.backend.list() else {
            adoptionPending = true
            return
        }
        try await adopt(inventory)
    }

    private func adopt(_ inventory: [TartVMInfo]) async throws {
        adoptionPending = false
        var known = Set(snapshot.environments.map(\.id))
        var changed = false
        for vm in inventory where vm.source == .local {
            guard let id = Self.managedEnvironment(named: vm.name), !known.contains(id) else { continue }
            do {
                try snapshot.slots.reserve(id)
            } catch {
                continue
            }
            // The CLI's output is untrusted: a name it repeats must adopt one environment, not
            // append a second record that makes every later snapshot save fail.
            known.insert(id)
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

    /// The registered VM's own entry in a `tart list`, which can only be a local one.
    ///
    /// Adoption manages local bundles alone, and an environment is registered against the
    /// bundle in `TART_HOME`. An OCI entry carrying the same name is a pulled image, not that
    /// bundle: matching on the name alone would let a registered bundle be deleted and the
    /// start still journal and launch, against an image Tart may go and fetch rather than
    /// against the VM the environment was registered with (MVP-PLAN.md §4).
    static func localVM(named name: String, in inventory: [TartVMInfo]) -> TartVMInfo? {
        inventory.first { $0.name == name && $0.source == .local }
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
                // A running VM settles an interrupted start and nothing else. The `tart stop` an
                // interrupted service left behind, and the guest shutdown it asked for, can
                // still finish afterwards; an interrupted import, provisioning, export, delete
                // or repair changed things a running VM says nothing about. Each of those waits
                // for its own state-specific check (MVP-PLAN.md §3).
                if unresolved[id]?.operation == .startEnvironment {
                    await settleInterruptedOperation(id)
                }
            case .uncertain:
                break
            }
        }
        self.verdicts = verdicts
        if inventory != nil {
            // A readable inventory with no verdict and no supervised process establishes that
            // no VM of ours is running, which settles a start or a stop and nothing else:
            // `settledByVMState` keeps every other kind of record unresolved until the check
            // that inspects what it actually changed can answer for it.
            for id in unresolved.keys where verdicts[id] == nil && supervised[id] == nil {
                await settleInterruptedOperation(id)
            }
        }
        reconciledAt = Date()
    }

    /// Whether observing the VM itself establishes this operation's outcome.
    ///
    /// Starting and stopping a VM are exactly the operations the VM's own state answers for. An
    /// import, a provisioning stage, an export, a delete, or a repair changed the filesystem or
    /// the guest, and a VM that is running or absent says nothing about how far any of them
    /// got; each waits for the check that inspects what it actually touched (MVP-PLAN.md §3).
    static func settledByVMState(_ operation: JournalOperation) -> Bool {
        switch operation {
        case .startEnvironment, .stopEnvironment: true
        case .provision, .importXcode, .deleteEnvironment, .exportWork, .repair: false
        }
    }

    /// Settles a journal `begin` whose failure does not say whether the record landed.
    ///
    /// `begin` synchronizes the `started` line before the journal's own directory entry, so a
    /// failure at that second step throws over a record a later read in this same service sees.
    /// Left alone, nothing here would track it: status would report the environment ready while
    /// the store refuses every later mutation for it as `operationUnresolved`, and no inspection
    /// would try to settle it until the service restarted. Nothing had run when the write
    /// failed — the launch and the signal both come after it — so a record that did land is
    /// closed as `notApplied`, which is the truthful terminal outcome for a mutation that never
    /// took effect; when even that cannot be written, the operation is held as unresolved so
    /// the next inspection can settle it (MVP-PLAN.md §3).
    func reconcileIndeterminateBegin(_ operation: OperationID, kind: JournalOperation, environment: EnvironmentID) async {
        // A journal that cannot be read now leaves the same unknown, and the environment has to
        // carry it: reporting nothing would license the very blind retry the journal prevents.
        guard let replay = try? await deps.store.replay() else {
            unresolved[environment] = JournalRecord(id: operation, environmentID: environment, operation: kind, timestamp: Date(), outcome: .started)
            return
        }
        guard let record = replay.inFlight[operation] else { return }
        do {
            try await deps.store.append(JournalRecord(id: operation, environmentID: environment, operation: kind, timestamp: Date(), outcome: .notApplied))
        } catch {
            unresolved[environment] = record
        }
    }

    private func settleInterruptedOperation(_ id: EnvironmentID) async {
        guard let record = unresolved[id], Self.settledByVMState(record.operation) else { return }
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

    public func environments() async throws -> [DevelopmentEnvironment] {
        // A hand-created VM that an unreadable inventory hid at launch is adopted on the next
        // listing. Without this it would stay invisible — never listed, so never inspected and
        // never reconciled — until the service process happened to restart (MVP-PLAN.md §4).
        //
        // An inventory that still cannot be read is reported rather than swallowed. The launch
        // deliberately survives it, but a listing that could not be completed is not a list:
        // answering with the snapshot alone would present "we could not look" as "there is
        // nothing", and the user would never be offered the repair or the state inspection the
        // failure carries.
        if adoptionPending { try await adopt(self.inventory()) }
        return snapshot.environments
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
        let (vm, initialReadiness) = try await vmState(of: environment, inventory: inventory)
        var readiness = initialReadiness
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
        // The address the field promises is one a guest connection can be made to, so it is
        // answered from the state just computed rather than from the supervised entry alone. A
        // VM that exited moments ago is observed as absent and reported stopped while its entry
        // still holds the address it had until the exit watcher runs, and handing that out
        // would point SSH and Screen Sharing at an endpoint this VM no longer owns (§4).
        let address: GuestIPAddress? = if case .running = vm { supervised[id]?.address } else { nil }
        return EnvironmentStatus(
            environmentID: id,
            vm: vm,
            readiness: readiness,
            inFlightOperation: inFlight?.environment == id ? inFlight?.id : nil,
            guestAddress: address,
            reconciledAt: reconciledAt
        )
    }

    /// What the VM is doing, and what that asks of the user.
    ///
    /// The supervised process is asked of the kernel rather than remembered, and a process
    /// table that declines to describe it is uncertainty, never an exit: reporting "cannot be
    /// read" as "stopped" would show a VM that may still be running as available and license a
    /// start over it (MVP-PLAN.md §4).
    private func vmState(of environment: DevelopmentEnvironment, inventory: [TartVMInfo]) async throws -> (EnvironmentStatus.VMState, EnvironmentStatus.Readiness) {
        let id = environment.id
        switch supervised[id].map({ deps.supervisor.observe($0.identity) }) ?? .absent {
        case .present:
            // Asked again on every inspection rather than cached once: Tart's NAT address can
            // change while the same VM process lives, most visibly after the host sleeps, and
            // a stale address sends SSH and Screen Sharing to the wrong endpoint (§4).
            let address: GuestIPAddress?
            do {
                address = try await deps.backend.ip(vmName: environment.tartVMName, wait: .seconds(0))
            } catch TartInvocationError.runtimeReplaced {
                // The inventory above proved the runtime a moment ago; it can be replaced
                // between that and this probe. Guesthouse then refused to execute it and no
                // guest was contacted, so swallowing this would send the user to inspect a
                // guest that was never asked, instead of to repair the runtime (§3).
                throw GuesthouseError.runtimeVerificationFailed(check: .signature)
            } catch is ProcessLaunchError {
                // Same window, and the same distinction: the runtime program could not be
                // started at all, which reinstalling it repairs.
                throw GuesthouseError.runtimeMissing
            } catch {
                // Everything else this probe reports — a timeout, no lease yet, a VM Tart says
                // is not running — is about the guest, and is the readiness below.
                address = nil
            }
            // The lookup suspends. A VM that ended while it was in flight was released by its
            // exit watcher, and an address is no evidence about a process that is gone, so the
            // answer is recomputed from what is true now.
            guard let current = supervised[id], case .present = deps.supervisor.observe(current.identity) else { break }
            supervised[id]?.address = address
            // Running without a confirmed address is not ready: nothing guest-dependent works.
            return (.running, address != nil ? .ready : .needsAttention(.guestNotReachable(id)))
        case .unavailable:
            return (
                .uncertain(reason: SanitizedText(Self.describe(.processUnobservable), limit: 200)),
                .needsAttention(.vmOwnershipUncertain(id))
            )
        case .absent:
            break
        }
        if case .uncertain(let reason)? = verdicts[id] {
            return (.uncertain(reason: SanitizedText(Self.describe(reason), limit: 200)), .needsAttention(.vmOwnershipUncertain(id)))
        }
        guard let info = Self.localVM(named: environment.tartVMName, in: inventory) else {
            return (.notFound, .needsAttention(.environmentNotFound(id)))
        }
        // Running according to Tart with no supervised process and no owned verdict.
        guard !info.running else {
            return (.uncertain(reason: "running without a recorded owner"), .needsAttention(.vmOwnershipUncertain(id)))
        }
        return (.stopped, .ready)
    }

    // MARK: - Operations

    /// Journals, launches, supervises, and waits for the guest's address. Returns the
    /// operation id once the journal has it and the launch is under way; progress and the
    /// result arrive through `events`.
    public func start(_ id: EnvironmentID, options: StartOptions, events: @escaping EventSink) async throws -> OperationID {
        guard let environment = snapshot.environments.first(where: { $0.id == id }) else { throw GuesthouseError.environmentNotFound(id) }
        try refuseIfBlocked(id)
        // Any slot whose ownership is unknown may still have a VM running: its recorded process
        // could not be read, or its inventory could not be. Starting a second VM over that is
        // what the one-running-VM invariant forbids (MVP-PLAN.md §4).
        if let other = verdicts.keys.sorted(by: { $0.tartVMName < $1.tartVMName }).first(where: { key in
            if case .uncertain? = verdicts[key] { return key != id } else { return false }
        }) {
            throw GuesthouseError.vmOwnershipUncertain(other)
        }
        guard snapshot.slots.state(of: id) == .active else { throw GuesthouseError.environmentPreserved(id) }
        if supervised[id] != nil { throw GuesthouseError.environmentAlreadyRunning(id) }
        if let other = supervised.keys.first(where: { $0 != id }) { throw GuesthouseError.anotherEnvironmentRunning(other) }

        // The slot is taken before the first suspension, so two simultaneous starts cannot
        // both pass the checks and launch two instances against one disk.
        let operation = OperationID()
        inFlight = InFlight(id: operation, environment: id, task: nil)
        let inventory: [TartVMInfo]
        do {
            inventory = try await self.inventory()
            // A registered VM whose bundle is gone from the store cannot be started. Without
            // this, `tart run` is launched, exits before its identity can be recorded, and the
            // failure reads as unavailable saved state instead of the missing VM it is.
            guard let info = Self.localVM(named: environment.tartVMName, in: inventory) else {
                throw GuesthouseError.environmentNotFound(id)
            }
            if info.running { throw GuesthouseError.environmentAlreadyRunning(id) }
            // Every running app-managed VM counts against the one-running-VM invariant,
            // including a `guesthouse-<uuid>` the snapshot does not know: adoption may have
            // found no free slot for it, but it is still one of ours and still running (§4).
            let runningManaged = inventory.filter(\.running).compactMap { Self.managedEnvironment(named: $0.name) }.filter { $0 != id }
            // One that has no slot is ours by name only; nothing records that Guesthouse
            // started it. It is reported as the uncertain ownership it is, which offers the
            // inspection and the console the developer needs, rather than a "stop it first"
            // for a VM `stop` would refuse as unregistered (§4).
            if let unadopted = runningManaged.first(where: { other in !snapshot.environments.contains { $0.id == other } }) {
                throw GuesthouseError.vmOwnershipUncertain(unadopted)
            }
            if let other = runningManaged.first {
                throw GuesthouseError.anotherEnvironmentRunning(other)
            }
            // The inventory alone cannot say the VM is free: a `tart run` for it may have
            // spawned without having taken the lock yet. The process table is asked for
            // claimants immediately before the journal entry, and again before the launch (§4).
            try await refuseIfAnySlotIsClaimed(startingFor: id, inventory: inventory)
        } catch {
            inFlight = nil
            throw error
        }
        do {
            _ = try await deps.store.begin(.startEnvironment, for: id, id: operation)
        } catch {
            inFlight = nil
            await reconcileIndeterminateBegin(operation, kind: .startEnvironment, environment: id)
            throw error
        }
        let token = deps.supervisor.hold("startEnvironment \(operation)")
        inFlight?.task = Task { [weak self] () async -> Void in
            guard let self else { return }
            await self.performStart(operation, environment: environment, options: options, inventory: inventory, token: token, events: events)
        }
        return operation
    }

    /// Refuses a start while any registered slot has a claimant, or an ownership that cannot be
    /// established.
    ///
    /// Every slot is scanned, not only the one being started: a `tart run` that has spawned but
    /// not yet taken its lock is in no inventory, and it may be claiming any of them, so
    /// launching over it would put two VMs on one disk and break the one-running-VM invariant
    /// (MVP-PLAN.md §4). The scan reads the process table, which only answers for the instant
    /// it was taken — callers repeat it after every suspension that precedes the launch.
    private func refuseIfAnySlotIsClaimed(startingFor id: EnvironmentID, inventory: [TartVMInfo]) async throws {
        let running = Set(inventory.filter(\.running).map(\.name))
        let registered = Dictionary(uniqueKeysWithValues: snapshot.environments.map { ($0.id, $0) })
        let fresh = await deps.supervisor.reconcile(environments: Array(registered.keys)) { other in
            guard let environment = registered[other] else { return .absent }
            return running.contains(environment.tartVMName) ? .present : .absent
        }
        // The environment being started is answered for first and the rest in a stable order,
        // so one process table always produces the same refusal.
        for other in fresh.keys.sorted(by: { ($0 == id ? "" : $0.tartVMName) < ($1 == id ? "" : $1.tartVMName) }) {
            guard case .uncertain? = fresh[other] else { continue }
            verdicts[other] = fresh[other]
            throw GuesthouseError.vmOwnershipUncertain(other)
        }
    }

    private func performStart(_ operation: OperationID, environment: DevelopmentEnvironment, options: StartOptions, inventory: [TartVMInfo], token: OperationSupervisor.Token, events: @escaping EventSink) async {
        defer { token.end(); inFlight = nil }
        let id = environment.id
        outputSinks[id] = (operation, events)
        defer { token.end(); inFlight = nil; outputSinks[id] = nil }
        let arguments = TartBackend.runArguments(vmName: environment.tartVMName, console: options.console)
        do {
            report(operation, ProgressPhase(kind: .startingVM, cancelable: false), events)
            // The claimant scan that preceded the journal entry was already stale when the
            // awaited write returned: another `tart run` can have spawned in between and be
            // taking the lock now. The process table is therefore read once more here, with
            // nothing but the launch after it. The inventory is the one already fetched — a VM
            // that took a lock since has a process this scan finds anyway, and a second `tart
            // list` would let a hanging inventory hold up a launch it cannot inform.
            try await refuseIfAnySlotIsClaimed(startingFor: id, inventory: inventory)
            let run = try await deps.backend.run(vmName: environment.tartVMName, console: options.console)
            drainOutput(of: run, environment: id)
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
            guard let live = supervised[id], live.pid == run.processIdentifier else {
                throw GuesthouseError.guestNotReachable(id)
            }
            // The watcher is asynchronous and may not have noticed an exit yet, so the kernel
            // is asked directly rather than trusting the entry that is still there. A process
            // table that will not answer leaves the outcome unestablished, not complete (§4).
            switch deps.supervisor.observe(live.identity) {
            case .present: break
            case .absent: throw GuesthouseError.guestNotReachable(id)
            case .unavailable: throw GuesthouseError.operationOutcomeUnknown(operation)
            }
            supervised[id]?.address = address
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .startEnvironment, timestamp: Date(), outcome: .completed))
            // The operation is complete whatever a best-effort status refresh does now, so the
            // refresh is bounded: an inventory that hangs must not delay the terminal event.
            if let status = await refreshedStatus(of: id) { events(.status(status)) }
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
        do {
            // Proven here so a stop this service may not perform is refused before it is
            // journaled; proven again in the task, because this answer is stale by then.
            _ = try await requireOwnershipToStop(environment)
        } catch {
            inFlight = nil
            throw error
        }
        do {
            _ = try await deps.store.begin(.stopEnvironment, for: id, id: operation)
        } catch {
            inFlight = nil
            await reconcileIndeterminateBegin(operation, kind: .stopEnvironment, environment: id)
            throw error
        }
        let token = deps.supervisor.hold("stopEnvironment \(operation)")
        inFlight?.task = Task { [weak self] () async -> Void in
            guard let self else { return }
            await self.performStop(operation, environment: environment, mode: mode, token: token, events: events)
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
        // A verdict is one reconciliation's memory. The process it named can have exited since,
        // and another launch can have taken the same VM name; authorizing a stop from the
        // remembered verdict alone would let Guesthouse shut down a machine that is no longer
        // the one it recorded, so the recorded identity is asked of the kernel again (§4).
        if case .ownedRunning(let recorded)? = verdicts[environment.id],
           let identity = await deps.supervisor.identity(for: environment.id),
           identity.pid == recorded.pid,
           deps.supervisor.verify(identity) != nil {
            return false
        }
        switch await observe(environment) {
        case .stopped: return true
        case .running, .unknown: throw GuesthouseError.vmOwnershipUncertain(environment.id)
        }
    }

    private func performStop(_ operation: OperationID, environment: DevelopmentEnvironment, mode: StopMode, token: OperationSupervisor.Token, events: @escaping EventSink) async {
        defer { token.end(); inFlight = nil }
        let id = environment.id
        outputSinks[id] = (operation, events)
        defer { token.end(); inFlight = nil; outputSinks[id] = nil }
        do {
            // Ownership was proven before the journal write suspended, and that answer only
            // described the instant it was taken: the owned process can have exited since and
            // another launch taken the same VM name, and the observed stopped state can have
            // become a running VM again. Both signals act by name or by PID, so ownership is
            // established once more here, immediately before either of them, and an ownership
            // that changed is reported as uncertain rather than stopped (MVP-PLAN.md §4).
            let alreadyStopped = try await requireOwnershipToStop(environment)
            switch mode {
            case .graceful(let deadline):
                report(operation, ProgressPhase(kind: .stoppingVM, cancelable: false), events)
                if !alreadyStopped {
                    // One deadline covers the whole graceful stop. `tart stop` and the wait for
                    // the process hosting the VM share it, so a normal Quit never takes close
                    // to twice what the caller asked for (MVP-PLAN.md §2).
                    let end = ContinuousClock.now.advanced(by: deadline)
                    try await gracefulStop(operation, environment: environment, deadline: deadline)
                    // Tart's command has returned, but the process hosting the VM may still be
                    // unwinding, and Quit waits for both. The run itself was launched with a
                    // year-long timeout, so an unbounded wait here would never end.
                    guard await waitForVMProcess(of: id, until: end) else {
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
                        try await endUnsupervisedVM(environment, operation: operation)
                    }
                }
            }
            await settleOutput(of: id)
            if let failure = await release(id) {
                throw GuesthouseError.runtimeStateUnavailable(reason: SanitizedText(Self.describe(failure), limit: 200))
            }
            try await deps.store.append(JournalRecord(id: operation, environmentID: id, operation: .stopEnvironment, timestamp: Date(), outcome: .completed))
            // The stop is already durable, so the courtesy status is bounded: an inventory that
            // hangs must not hold Quit past the deadline for a stop that already succeeded.
            if let status = await refreshedStatus(of: id) { events(.status(status)) }
            events(.completed(operation))
        } catch is CancellationError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: .canceled, events: events)
        } catch let error as GuesthouseError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: error, events: events)
        } catch let error as TartInvocationError {
            await fail(operation, kind: .stopEnvironment, environment: id, with: Self.map(error, environment: id), events: events)
        } catch is ProcessLaunchError {
            // `tart` itself could not be launched, so nothing was asked of the VM. Guesthouse's
            // saved state is not involved, and reinstalling the runtime — not inspecting
            // state — is what helps, exactly as on the start path.
            await fail(operation, kind: .stopEnvironment, environment: id, with: .runtimeMissing, events: events)
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
            // The caller's whole budget is spent by definition on this branch, and when the
            // supervised process is already gone `observe` falls through to `tart list`, whose
            // own timeout is longer than a graceful stop's entire deadline: a Quit would sit
            // tens of seconds past what the user asked for. The read gets a short courtesy
            // window instead, and one that does not answer inside it is the unknown outcome
            // this branch already reports for a state it cannot read (MVP-PLAN.md §2).
            switch await observe(environment, within: Self.statusRefreshBudget) {
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
    private func waitForVMProcess(of id: EnvironmentID, until end: ContinuousClock.Instant) async -> Bool {
        guard let live = supervised[id] else { return true }
        let identity = live.identity
        return await poll(until: end) { deps.supervisor.observe(identity) == .absent }
    }

    private func poll(until end: ContinuousClock.Instant, _ finished: () -> Bool) async -> Bool {
        while true {
            if finished() { return true }
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Ends the VM for a force stop when no supervised process is left to signal.
    ///
    /// The supervised process can have exited between the ownership preflight and this task,
    /// in which case the requested stopped state is already reached and no command is needed:
    /// `tart stop` would answer `notRunning`, and that would be reported as a failure for a
    /// stop that succeeded (MVP-PLAN.md §2, Quit).
    func endUnsupervisedVM(_ environment: DevelopmentEnvironment, operation: OperationID) async throws {
        switch await observe(environment) {
        case .stopped: return
        case .running: try await deps.backend.stop(vmName: environment.tartVMName, deadline: .seconds(10))
        case .unknown: throw GuesthouseError.operationOutcomeUnknown(operation)
        }
    }

    /// A status read that gives up at `statusRefreshBudget`, for the courtesy refresh that
    /// precedes a terminal event. The operation it follows is already journaled, so a `tart
    /// list` that never answers must cost the client nothing.
    private func refreshedStatus(of id: EnvironmentID) async -> EnvironmentStatus? {
        await withTaskGroup(of: EnvironmentStatus?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return try? await self.status(of: id)
            }
            group.addTask {
                try? await Task.sleep(for: Self.statusRefreshBudget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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
        return Self.localVM(named: environment.tartVMName, in: inventory)?.running == true ? .running : .stopped
    }

    /// `observe`, giving up at `budget` with `.unknown`. Cancelling the group ends the query
    /// process too, so the wait really is bounded rather than merely abandoned.
    private func observe(_ environment: DevelopmentEnvironment, within budget: Duration) async -> VMObservation {
        await withTaskGroup(of: VMObservation.self) { group in
            group.addTask { [weak self] in
                guard let self else { return .unknown }
                return await self.observe(environment)
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return .unknown
            }
            let first = await group.next() ?? .unknown
            group.cancelAll()
            return first
        }
    }

    /// Cancels the in-flight operation if it is the one named. While the reported phase is
    /// not cancelable the request is deferred to the next phase that is; an operation whose
    /// remaining phases are all protected (a stop) runs to its end and reports its real
    /// outcome, so a second stop is never attempted over an unknown one.
    public func cancel(_ operation: OperationID) {
        guard let current = inFlight, current.id == operation else { return }
        // No phase yet means the operation has not reported one. Its first phase is a protected
        // one for both start and stop, and the task may not even exist yet, so cancelling here
        // would either be dropped or land on a task about to begin mutating; the request is
        // deferred to the next cancelable phase instead.
        guard let phase = current.phase, phase.cancelable else {
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

    /// Tart's output over a VM's lifetime is already redacted. While an operation on the
    /// environment is in flight each line is forwarded to it as a `log` event, so the GUI's
    /// diagnostics see what Tart said; otherwise the stream is consumed so the bounded buffer
    /// never fills.
    private func drainOutput(of run: ProcessRun, environment id: EnvironmentID) {
        draining.insert(id)
        drains[id] = Task { [weak self] in
            for await output in run.output {
                await self?.forward(output, from: id)
            }
            await self?.finishedDraining(id)
        }
    }

    private func finishedDraining(_ id: EnvironmentID) {
        draining.remove(id)
    }

    /// Waits, briefly, for output already read from the process to reach the operation's
    /// stream. A process that exits after writing its last lines resumes the exit waiters
    /// before this task has forwarded them, and those lines are exactly the ones that explain
    /// the failure. The wait is bounded: a pipe an inherited child still holds open must not
    /// keep the operation from finishing.
    private func settleOutput(of id: EnvironmentID, within limit: Duration = .milliseconds(500)) async {
        guard draining.contains(id) else { return }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while draining.contains(id), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func forward(_ output: ProcessOutput, from id: EnvironmentID) {
        guard let sink = outputSinks[id] else { return }
        switch output {
        case .stdout(let line), .stderr(let line):
            sink.events(.log(sink.operation, line))
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
        drains.removeValue(forKey: id)
        draining.remove(id)
        verdicts[id] = failure == nil ? nil : .uncertain(.identityNotForgotten)
        return failure
    }

    /// Journals the failure under the operation's own kind (the journal refuses a record whose
    /// kind differs from its `started` record), then reports it.
    private func fail(_ operation: OperationID, kind: JournalOperation, environment: EnvironmentID, with error: GuesthouseError, events: EventSink) async {
        await settleOutput(of: environment)
        do {
            try await deps.store.append(JournalRecord(id: operation, environmentID: environment, operation: kind, timestamp: Date(), outcome: .failed(error)))
            // A recorded outcome that is itself unknown settles nothing: the environment stays
            // blocked, and status keeps asking for inspection, until actual state says what
            // the mutation did. A cancellation is the same — the work may have been half done
            // when the task stopped — and `JournalRecord.leavesInFlight` reads both that way,
            // so both are tracked here or only a service restart would rediscover them.
            switch error {
            case .operationOutcomeUnknown, .canceled:
                unresolved[environment] = JournalRecord(id: operation, environmentID: environment, operation: kind, timestamp: Date(), outcome: .started)
            default:
                break
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

    /// Test seams: what the lifecycle is doing right now, before any progress has been
    /// reported for it.
    var inFlightOperationID: OperationID? { inFlight?.id }
    var inFlightPhase: ProgressPhase? { inFlight?.phase }

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
        } catch is ProcessLaunchError {
            // The runtime program itself could not be started, which reinstalling it repairs.
            // Guesthouse's saved state is not involved, so it must not be what the user is
            // sent to inspect.
            throw GuesthouseError.runtimeMissing
        }
    }

    /// How an inventory command's failure reads to the user, as distinct from `map`, which
    /// answers for commands addressed at one VM.
    public static func mapInventory(_ error: TartInvocationError) -> GuesthouseError {
        switch error {
        case .unparseableOutput: .runtimeIncompatible(found: nil, required: SanitizedText(TartPin.releaseTag))
        case .timedOut: .runtimeStateUnavailable(reason: SanitizedText("the list of virtual machines did not answer in time", limit: 200))
        case .runtimeReplaced: .runtimeVerificationFailed(check: .signature)
        case .failed: .runtimeStateUnavailable(reason: SanitizedText("the list of virtual machines could not be read", limit: 200))
        }
    }

    public static func map(_ error: TartInvocationError, environment: EnvironmentID) -> GuesthouseError {
        switch error {
        case .unparseableOutput: .runtimeIncompatible(found: nil, required: SanitizedText(TartPin.releaseTag))
        case .timedOut: .guestNotReachable(environment)
        // Guesthouse refused to execute a host runtime that is no longer the verified file.
        // Nothing was run and no guest was probed; reinstalling the runtime is what helps.
        case .runtimeReplaced: .runtimeVerificationFailed(check: .signature)
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
