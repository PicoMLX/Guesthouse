import Foundation
import GuesthouseCore
import Observation
import Synchronization

/// The app's top-level state: what the runtime reports, and the Quit contract.
///
/// MVP-PLAN.md §2 ("Returning developer"): closing the window keeps Guesthouse running in the
/// menu bar; normal Quit offers "Stop environments and quit" or "Cancel", waits for the guest
/// and Tart to stop, and offers cancellation or an explicitly warned force-stop if graceful
/// stop fails; after a crash or disconnection the app shows "Checking environment" rather than
/// a cached Ready state and reconciles before offering new operations.
@Observable
final class AppModel {
    enum LaunchState: Equatable {
        /// Reconciling with the runtime; no operations are offered.
        case checkingEnvironment
        case ready
        /// The runtime connection dropped; in-flight outcomes are unknown until re-checked.
        case interrupted(RuntimeConnectionInterrupted)
        case unavailable(GuesthouseError)
    }

    enum QuitFlow: Equatable {
        case idle
        /// The sheet is showing its two options.
        case confirming
        /// State is being reconciled before a stop is attempted, or after an unknown outcome.
        case checking
        /// Environments are being stopped; the app has told AppKit to wait.
        case stopping(EnvironmentID?, ProgressPhase?)
        /// Graceful stop failed; the sheet offers the warned force-stop, or a check first.
        case stopFailed(GuesthouseError)
        /// The pre-stop check lost its answer. Nothing was mutated, so the interruption's own
        /// read-only recovery is offered instead of an operation outcome the app never had.
        case checkFailed(RuntimeConnectionInterrupted)
        case forceStopping(EnvironmentID?)
        /// Everything stopped; AppKit has been told to terminate.
        case terminating
    }

    /// An operation this app started and is still listening to.
    struct OperationState: Equatable {
        var id: OperationID
        var phase: ProgressPhase?
    }

    static let gracefulStopDeadline: Duration = .seconds(60)

    private(set) var launchState: LaunchState = .checkingEnvironment
    private(set) var environments: [DevelopmentEnvironment] = []
    private(set) var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    private(set) var operations: [EnvironmentID: OperationState] = [:]
    /// The last failure per environment, cleared when an operation completes.
    private(set) var lastErrors: [EnvironmentID: GuesthouseError] = [:]
    private(set) var quitFlow: QuitFlow = .idle
    /// The user canceled during a step that must run to its end; honored when it ends.
    private(set) var quitCancelRequested = false
    /// Shown alongside the Quit sheet: external Codex work cannot be enumerated.
    let quitWarning = "Stopping a development Mac interrupts any Codex task running in it. Guesthouse cannot see those tasks; finish them first."

    let backend: any RuntimeBackend
    private let terminationDecision: @MainActor (Bool) -> Void
    private var quitTask: Task<Void, Never>?
    /// Identifies one Quit attempt. Every asynchronous step checks it, so a cancelled check
    /// can never rejoin a later attempt.
    private var quitGeneration: UInt64 = 0
    /// Environments whose graceful stop failed. Only these are force-stopped.
    private var gracefulFailures: Set<EnvironmentID> = []
    /// The model's own reconciliation task, so closing a window cannot cancel it.
    private var refreshTask: Task<Void, Never>?
    /// Set for as long as that task is alive. Taken before the task starts, so two presses in
    /// one turn cannot both start one.
    private var refreshIsRunning = false
    /// Set when a reconciliation ended `unavailable`: further connection drops no longer
    /// reconnect on their own, so the app stays on the recovery the error prescribes.
    private var automaticReconciliationSuspended = false
    /// The idle-loss observation; canceled from `deinit`, which is not actor-isolated.
    private let interruptionObservation = CancelOnDeinit()
    /// Bumped by every `refresh()`; a refresh whose generation is no longer current does not
    /// publish its result.
    private var refreshGeneration: UInt64 = 0
    /// How many reconciliations are reading from the runtime right now. A loss reported while
    /// one is running belongs to that reconciliation, which reports it itself.
    private var reconciliationsInFlight = 0
    /// A loss left to the reconciliation that was reading when it arrived. The client throws
    /// into the streams it cut off, but a reconciliation whose last query had already been
    /// answered has nothing left to throw into, so the loss is kept here and settles that
    /// reconciliation's own result instead of being discarded.
    private var lossLeftToReconciliation: RuntimeConnectionInterrupted?

    /// - Parameters:
    ///   - backend: the runtime, or a fake for previews and tests.
    ///   - terminationDecision: how the final Quit decision reaches AppKit
    ///     (`NSApplication.reply(toApplicationShouldTerminate:)` in the app).
    init(backend: any RuntimeBackend, terminationDecision: @escaping @MainActor (Bool) -> Void) {
        self.backend = backend
        self.terminationDecision = terminationDecision
        interruptionObservation.task = Task { [weak self] in
            for await interruption in backend.connectionInterruptions() {
                self?.connectionInterrupted(interruption)
            }
        }
    }

    deinit {
        interruptionObservation.cancel()
    }

    /// Picks the real client, or the fake when the app is hosting unit tests, so a test run
    /// never launches the runtime service.
    ///
    /// `GUESTHOUSE_FAKE_RUNTIME=1` selects the fake too, but only in a development build. In a
    /// shipped app an environment variable must not be able to replace the runtime with an
    /// empty in-memory one: reconciliation would then find no environments, and Quit would
    /// conclude there is nothing to stop and approve termination with a real VM still running
    /// (MVP-PLAN.md §2).
    static func makeBackend(environment: [String: String] = ProcessInfo.processInfo.environment) -> any RuntimeBackend {
        if environment["XCTestConfigurationFilePath"] != nil { return FakeRuntimeBackend() }
        #if DEBUG
        if environment["GUESTHOUSE_FAKE_RUNTIME"] == "1" { return FakeRuntimeBackend() }
        #endif
        return RuntimeClient()
    }

    // MARK: - Reconciliation

    /// Re-reads everything from the runtime. Never trusts a cached Ready: a refresh that was
    /// canceled or overtaken by a newer one publishes nothing, leaving "Checking environment"
    /// to the refresh that replaced it.
    /// Starts a reconciliation owned by the model. A window that closes cannot cancel it, so
    /// the menu bar and any surviving window still leave "Checking environment".
    ///
    /// A Quit in progress owns its own reconciliation and reads its decision out of the state
    /// that one publishes. A refresh started here would retire that generation, leaving the
    /// Quit to read "checking" as a check that failed and stranding the sheet on a failure the
    /// newer result disproves — so while the sheet is up, its check is the one that runs
    /// (MVP-PLAN.md §2). `canCheckEnvironment` lets a menu say so rather than do nothing.
    func startRefresh() {
        guard canCheckEnvironment else { return }
        startRefreshTask()
    }

    /// Whether a check may be started from outside the Quit flow. A check that is already
    /// reading answers for the one being asked for, so the menu shows the action as
    /// unavailable rather than appearing to do nothing.
    var canCheckEnvironment: Bool { quitFlow == .idle && !refreshIsRunning }

    /// One model-owned reconciliation at a time, and a second request joins it rather than
    /// replacing it.
    ///
    /// Cancelling the local task does not cancel the request the service is already working on:
    /// the client only notes that the consumer went away, and `RuntimeService` keeps counting
    /// that request against the session until it replies. So a check started for every press
    /// while a slow one is in flight would spend the session's eight-request cap on checks
    /// nobody is waiting for, and the next real request would be refused as `tooManyInFlight`
    /// and published as an unavailable runtime — for a service that is merely slow
    /// (MVP-PLAN.md §2). The check in flight is the fresh one; joining it is the whole answer.
    private func startRefreshTask() {
        guard !refreshIsRunning else { return }
        refreshIsRunning = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            self.refreshIsRunning = false
        }
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        // Every refresh is something the user or a flow asked for, so it lifts the suspension
        // a previous failure imposed: otherwise repairing the runtime would never restore
        // automatic reconciliation without relaunching the app.
        automaticReconciliationSuspended = false
        launchState = .checkingEnvironment
        reconciliationsInFlight += 1
        let outcome = await reconcile()
        reconciliationsInFlight -= 1
        // Left set for the refresh that replaced this one: a retired result publishes nothing,
        // so it must not consume the loss its successor still has to answer for.
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        // A loss that arrived while this reconciliation was reading was left to it to report,
        // because the client throws into the streams the same loss cut off. When every query
        // had already been answered nothing threw, and nothing else will: `connectionDropped`
        // only reaches accepted operations. This result therefore describes a session that is
        // gone, and publishing it as Ready would leave that state on screen until the user
        // happened to ask again, so the loss settles the refresh instead (MVP-PLAN.md §2).
        var settled = outcome
        if let loss = lossLeftToReconciliation, case .ready = outcome { settled = .interrupted(loss) }
        lossLeftToReconciliation = nil
        switch settled {
        case .ready(let listed, let fresh):
            environments = listed
            statuses = fresh
            launchState = .ready
            Task { await pollRecoveredOperations() }
        case .unavailable(let error):
            launchState = .unavailable(error)
            // An unavailable runtime is not something reconnecting fixes: the error carries
            // its own recovery, and the app stays on it until the user asks again.
            automaticReconciliationSuspended = true
        case .interrupted(let interruption):
            launchState = .interrupted(interruption)
            // A reconciliation that was itself cut off would otherwise be restarted by the
            // loss it just suffered, relaunching a service that keeps crashing forever. The
            // interruption recovery stays on screen until the user asks for another check.
            automaticReconciliationSuspended = true
        }
    }

    private enum ReconcileOutcome {
        case ready([DevelopmentEnvironment], [EnvironmentID: EnvironmentStatus])
        case unavailable(GuesthouseError)
        case interrupted(RuntimeConnectionInterrupted)
    }

    private func reconcile() async -> ReconcileOutcome {
        do {
            var listed: [DevelopmentEnvironment] = []
            for try await event in backend.send(.listEnvironments) {
                switch event {
                case .environments(let environments): listed = environments
                case .failed(_, let error): return .unavailable(error)
                default: break
                }
            }
            var fresh: [EnvironmentID: EnvironmentStatus] = [:]
            for environment in listed {
                for try await event in backend.send(.environmentStatus(environment.id)) {
                    if case .status(let status) = event { fresh[environment.id] = status }
                    if case .failed(_, let error) = event { return .unavailable(error) }
                }
            }
            return .ready(listed, fresh)
        } catch let error as RuntimeConnectionInterrupted {
            return .interrupted(error)
        } catch {
            return .interrupted(RuntimeConnectionInterrupted())
        }
    }

    /// The service went away while nothing was in flight. In-flight streams report their own
    /// loss; here the cached state is dropped and reconciliation starts again. During a quit
    /// the stop stream itself reports the loss.
    func connectionInterrupted(_ interruption: RuntimeConnectionInterrupted) {
        switch quitFlow {
        case .idle:
            break
        case .confirming, .stopFailed, .checkFailed:
            // A suspended reconciliation means the sheet already shows a failure that carries
            // its own recovery and that another check only reproduces. The service closing an
            // incompatible session behind that failure would otherwise reopen it, reach the
            // same verdict, and relaunch the service for as long as the sheet is up.
            guard !automaticReconciliationSuspended else {
                quitGeneration &+= 1
                quitFlow = quitFailure()
                return
            }
            // The sheet is open on state that is now stale: nothing is offered again until
            // the environments have been read back. That reconciliation refreshes the model
            // itself, and it is the only one started here: a second refresh would retire its
            // generation, so the sheet would land on a failure the newer refresh disproves.
            quitGeneration &+= 1
            quitFlow = .checking
            let generation = quitGeneration
            launchState = .interrupted(interruption)
            quitTask = Task { [weak self] in
                guard let self else { return }
                await self.reconcileForQuit(generation: generation)
            }
            return
        case .checking, .stopping, .forceStopping, .terminating:
            // A stop stream reports its own loss; nothing to do here.
            return
        }
        // A suspended reconciliation means the last refresh published a failure that carries
        // its own recovery; replacing it with the generic interrupted screen would lose that
        // guidance and leave a check as the only offer.
        guard !automaticReconciliationSuspended else { return }
        // The real client yields this notification before it throws into the streams the same
        // loss cut off, so a reconciliation may still be reading. It reports the loss itself;
        // replacing it here would retire its generation, suppress the suspension its failure
        // sets, and reconnect in a loop to a service that keeps crashing. It is remembered
        // rather than dropped, because a reconciliation whose queries were already answered
        // has no stream left for the loss to arrive in and would otherwise publish a session
        // that is gone as Ready.
        guard reconciliationsInFlight == 0 else {
            lossLeftToReconciliation = interruption
            return
        }
        launchState = .interrupted(interruption)
        startRefreshTask()
    }

    /// Re-reads the environments for an interrupted Quit sheet and returns it to its options,
    /// or shows why it could not.
    private func reconcileForQuit(generation: UInt64) async {
        await refresh()
        guard generation == quitGeneration, case .checking = quitFlow else { return }
        quitFlow = launchState == .ready ? .confirming : quitFailure()
    }

    var runningEnvironments: [DevelopmentEnvironment] {
        environments.filter { statuses[$0.id]?.vm == .running }
    }

    /// What the menu bar says about a reconciled state. Ownership the runtime could not
    /// establish is named, never folded into "no development Mac running": that would report
    /// an unproven stopped state as fact (MVP-PLAN.md §4).
    var runningSummary: String {
        let running = runningEnvironments.count
        let uncertain = uncertainEnvironments.count
        guard uncertain > 0 else {
            return running == 0 ? "No development Mac running" : "\(running) running"
        }
        let unproven = "\(uncertain) development Mac\(uncertain == 1 ? "" : "s") Guesthouse cannot identify"
        return running == 0 ? unproven : "\(running) running, \(unproven)"
    }

    /// What the Quit confirmation says about the state it is about to act on.
    ///
    /// Ownership the runtime could not establish is named here as it is in the menu bar, never
    /// folded into "no development Mac is running": that reports an unproven stopped state as
    /// fact, and this is the sentence the user's Quit-or-Cancel decision is made on. The stop
    /// itself refuses over an uncertain environment, so promising a clean quit here would be
    /// contradicted a moment later (MVP-PLAN.md §4).
    var quitConfirmationMessage: String {
        let running = runningEnvironments.count
        let uncertain = uncertainEnvironments.count
        let stops = running == 1
            ? "Quitting stops the running development Mac first."
            : "Quitting stops all running development Macs first."
        guard uncertain > 0 else {
            return running == 0 ? "No development Mac is running." : stops
        }
        let unproven = uncertain == 1
            ? "Guesthouse cannot tell whether one development Mac is running, and cannot stop it until that is checked."
            : "Guesthouse cannot tell whether \(uncertain) development Macs are running, and cannot stop them until that is checked."
        return running == 0 ? unproven : "\(stops) \(unproven)"
    }

    /// Environments whose VM ownership the runtime could not establish. Neither stop mode is
    /// safe on them, so they block quitting until a check resolves them.
    var uncertainEnvironments: [DevelopmentEnvironment] {
        environments.filter {
            if case .uncertain = statuses[$0.id]?.vm { return true }
            return false
        }
    }

    /// The runtime runs one lifecycle operation at a time and one VM at a time
    /// (MVP-PLAN.md §4, §6), so a start on any card is refused while another environment is
    /// running or any operation is in flight.
    var globalStartBlock: String? {
        if let busy = operations.keys.first ?? statuses.values.first(where: { $0.inFlightOperation != nil })?.environmentID,
           let name = environments.first(where: { $0.id == busy })?.name {
            return "An operation is in progress on \(name)."
        }
        if let running = runningEnvironments.first {
            return "\(running.name) is running. Guesthouse runs one development Mac at a time until resource validation allows two."
        }
        return nil
    }

    /// Statuses that name an operation this app did not start (one recovered after a
    /// relaunch) are re-queried until they become terminal, so a card never stays busy for
    /// an operation nobody observes.
    func pollRecoveredOperations() async {
        while !Task.isCancelled {
            let recovered = statuses.values.filter { $0.inFlightOperation != nil && operations[$0.environmentID] == nil }.map(\.environmentID)
            if recovered.isEmpty { return }
            try? await Task.sleep(for: .seconds(2))
            for id in recovered { await refreshStatus(of: id) }
        }
    }

    /// Re-reads one environment's status after an operation, whatever its outcome.
    func refreshStatus(of id: EnvironmentID) async {
        do {
            for try await event in backend.send(.environmentStatus(id)) {
                if case .status(let status) = event { statuses[id] = status }
            }
        } catch {
            launchState = .interrupted(RuntimeConnectionInterrupted())
        }
    }

    // MARK: - Dashboard

    /// One card per environment, in creation order.
    func cardStates() -> [EnvironmentCardState] {
        let block = globalStartBlock
        return environments.map { environment in
            EnvironmentCardState(
                environment: environment,
                status: statuses[environment.id],
                operation: operations[environment.id],
                lastError: lastErrors[environment.id],
                startBlockedElsewhere: (operations[environment.id] == nil && statuses[environment.id]?.vm != .running) ? block : nil
            )
        }
    }

    /// Whether a new development Mac can be created. At most two exist, stopped and
    /// preserved ones included (MVP-PLAN.md §1).
    var createAvailability: EnvironmentCardState.Availability {
        guard launchState == .ready else { return .disabled(reason: "Checking environment") }
        if environments.count >= VMSlotInventory.maximumSlots {
            return .disabled(reason: "Guesthouse manages at most \(VMSlotInventory.maximumSlots) development Macs, including stopped and preserved ones. Export any unpublished work from one you no longer need, then delete it to make room.")
        }
        return .enabled
    }

    /// Starts an environment. The only dashboard action wired to the runtime so far.
    func start(_ id: EnvironmentID) {
        guard environments.contains(where: { $0.id == id }), operations[id] == nil, globalStartBlock == nil else { return }
        Task { await run(.startEnvironment(id, StartOptions()), for: id) }
    }

    private func run(_ request: RuntimeRequest, for id: EnvironmentID) async {
        lastErrors[id] = nil
        operations[id] = OperationState(id: OperationID(), phase: nil)
        do {
            for try await event in backend.send(request) {
                switch event {
                case .accepted(let operation): operations[id] = OperationState(id: operation, phase: nil)
                case .progress(_, let phase): operations[id]?.phase = phase
                case .status(let status): statuses[status.environmentID] = status
                case .failed(_, let error): lastErrors[id] = error
                case .completed: lastErrors[id] = nil
                default: break
                }
            }
        } catch {
            // The outcome is unknown until the runtime is asked again; never replay.
            launchState = .interrupted(RuntimeConnectionInterrupted())
        }
        operations[id] = nil
        await refreshStatus(of: id)
    }

    /// A model over a preview scenario's environments and scripted backend, already refreshed.
    static func preview(_ scenario: PreviewScenario) async -> AppModel {
        await scenario.backend.setEnvironments(scenario.snapshot.environments)
        let model = AppModel(backend: scenario.backend) { _ in }
        await model.refresh()
        if let request = scenario.initialRequest, case .startEnvironment(let id, _) = request {
            model.start(id)
        }
        return model
    }

    // MARK: - Quit contract

    /// AppKit asked whether to terminate. Returns false when the sheet must be shown first.
    func handleQuitRequest() -> Bool {
        switch quitFlow {
        case .terminating: return true
        case .idle: quitFlow = .confirming; return false
        default: return false
        }
    }

    /// The user chose "Stop environments and quit". The flow leaves `confirming` synchronously,
    /// so a second confirmation cannot start a second stop.
    func confirmStopAndQuit() {
        guard case .confirming = quitFlow else { return }
        quitCancelRequested = false
        // Failure bookkeeping belongs to one attempt: a target retained from a Quit the user
        // abandoned would otherwise be force-stopped here without being asked to shut down.
        gracefulFailures.removeAll()
        quitGeneration &+= 1
        let generation = quitGeneration
        quitFlow = launchState == .ready ? .stopping(nil, nil) : .checking
        quitTask = Task { await stopAllAfterReconciling(mode: .graceful(deadline: Self.gracefulStopDeadline), generation: generation) }
    }

    /// Whether the failure the sheet shows may be answered with a force-stop. After an unknown
    /// outcome or on uncertain ownership the state must be checked first: force-stopping a VM
    /// the app may not own, or one that may already have stopped, is never offered blind.
    /// A force-stop is offered only when the failure itself sanctions repeating the stop:
    /// an error whose recovery is inspection (an operation still in flight, an unknown
    /// outcome, uncertain ownership) is checked first, never forced past. A failure that no
    /// graceful stop produced — a quit-time reconciliation that could not complete — has no
    /// snapshot to force against, so it is never forceable either.
    var canForceStop: Bool {
        guard case .stopFailed(let error) = quitFlow, !gracefulFailures.isEmpty else { return false }
        switch error {
        case .operationOutcomeUnknown, .vmOwnershipUncertain: return false
        default: return error.recoveryActions.contains(.retry)
        }
    }

    /// What the Quit sheet offers next to Cancel. Taken from the failure itself: a check is
    /// offered only when the failure's own recovery calls for one, so a failure prescribing a
    /// repair or a reinstall is not answered with a check that returns the same failure and
    /// leaves the sheet without the applicable recovery.
    enum QuitRecovery: Equatable {
        case forceStop
        case check
        /// The failure prescribes something the Quit sheet cannot do; its guidance is shown.
        case guidance(String)
    }

    var quitRecovery: QuitRecovery? {
        switch quitFlow {
        case .stopFailed(let error):
            if canForceStop { return .forceStop }
            let actions = error.recoveryActions
            guard actions.contains(.inspectState) || actions.contains(.retry) else {
                return .guidance(error.recoverySuggestion ?? "Cancel to stay in Guesthouse and deal with this first.")
            }
            return .check
        case .checkFailed(let interruption):
            return interruption.recoveryActions.contains(.retry) ? .check : .guidance(interruption.recoveryMessage)
        default:
            return nil
        }
    }

    /// The user accepted the force-stop warning.
    func forceStopAndQuit() {
        guard canForceStop else { return }
        quitCancelRequested = false
        quitGeneration &+= 1
        let generation = quitGeneration
        quitFlow = .checking
        // The statuses on screen were read before the graceful stop failed, and the sheet then
        // waited for a person to read a warning. An environment can have been started outside
        // Guesthouse, or restarted after it stopped, in that time; forcing from that snapshot
        // would approve termination with a VM still running. State is read back first, and the
        // targets are chosen from it — only the environments whose graceful stop actually
        // failed are forced, anything else is still asked to shut down (MVP-PLAN.md §2).
        quitTask = Task { await stopAllAfterReconciling(mode: .force, generation: generation) }
    }

    /// After an unknown outcome or uncertain ownership the sheet offers a check: reconcile, then
    /// return to the confirmation with the real state, or show why the check failed.
    func inspectAndContinueQuit() {
        guard quitRecovery == .check else { return }
        quitGeneration &+= 1
        let generation = quitGeneration
        quitFlow = .checking
        quitTask = Task { await reconcileForQuit(generation: generation) }
    }

    /// The user canceled. A stop in a cancelable phase is abandoned at once; a phase the runtime
    /// marks as not cancelable, and a force-stop, are allowed to end first, after which the app
    /// stays open. Either way AppKit is told not to terminate, and a stop that ran partway is
    /// followed by a fresh check before operations are offered again.
    func cancelQuit() {
        switch quitFlow {
        case .idle, .terminating:
            return
        case .stopping(_, let phase?) where !phase.cancelable:
            quitCancelRequested = true
        case .stopping(.some, nil):
            // A stop that has not described a phase yet: it may not even be accepted. Neither
            // can be abandoned here. Every phase a stop reports is one the runtime protects,
            // so a `cancelOperation` — the one the client sends the moment an acceptance names
            // the operation, and the one it would send now — is deferred there exactly as it
            // is deferred here, and the guest shuts down either way. Dropping the stream would
            // only lose the outcome the sheet needs to tell a refused shutdown from a failure,
            // so the cancellation waits for it (MVP-PLAN.md §2).
            quitCancelRequested = true
        case .forceStopping:
            quitCancelRequested = true
        case .confirming:
            quitFlow = .idle
            terminationDecision(false)
        case .checking:
            // The check itself keeps running and lands on its own; only the quit is dropped,
            // and its generation is retired so it cannot rejoin a later attempt.
            quitGeneration &+= 1
            quitFlow = .idle
            quitTask = nil
            terminationDecision(false)
        case .stopping, .stopFailed, .checkFailed:
            quitTask?.cancel()
            finishCancel(reconcile: true)
        }
    }

    private func finishCancel(reconcile: Bool) {
        guard quitFlow != .idle else { return }
        quitGeneration &+= 1
        quitCancelRequested = false
        quitTask = nil
        quitFlow = .idle
        terminationDecision(false)
        // Through the model's own task, so this check is the one a later press joins rather
        // than an unstructured one that would run alongside it on the same session.
        if reconcile { startRefreshTask() }
    }

    /// How a check that did not end `ready` is presented on the sheet. A lost answer keeps its
    /// own read-only recovery: inventing an operation id for it would tell the user a mutation
    /// may have completed and replace the retry it prescribes with an inspection.
    private func quitFailure() -> QuitFlow {
        switch launchState {
        case .unavailable(let error): .stopFailed(error)
        case .interrupted(let interruption): .checkFailed(interruption)
        case .checkingEnvironment, .ready: .checkFailed(RuntimeConnectionInterrupted())
        }
    }

    /// Stop targets come from reconciled state, never from what was cached before the sheet:
    /// a VM started outside Guesthouse changes nothing the app can observe, so a cached Ready
    /// is not evidence about what is running (MVP-PLAN.md §2).
    private func stopAllAfterReconciling(mode: StopMode, generation: UInt64) async {
        guard generation == quitGeneration, !Task.isCancelled else { return }
        quitFlow = .checking
        await refresh()
        guard generation == quitGeneration, case .checking = quitFlow else { return }
        guard launchState == .ready else {
            quitFlow = quitFailure()
            return
        }
        // A start accepted moments ago has not reported `running` yet; the decision waits
        // for every active operation and re-reads the statuses before choosing targets.
        await waitForOperations()
        guard generation == quitGeneration, !Task.isCancelled, !quitCancelRequested else { finishCancel(reconcile: true); return }
        // The mode still decides how they are stopped: only the environments whose graceful
        // stop already failed are force-stopped.
        quitFlow = mode == .force ? .forceStopping(nil) : .stopping(nil, nil)
        // An operation the runtime still reports is unresolved, whatever the VM state says:
        // quitting over it could leave a VM the app never saw start.
        if let busy = statuses.values.first(where: { $0.inFlightOperation != nil }), let operation = busy.inFlightOperation {
            quitFlow = .stopFailed(.operationOutcomeUnknown(operation))
            return
        }
        await stopAll(mode: mode, generation: generation)
    }

    private func waitForOperations() async {
        while !operations.isEmpty, !Task.isCancelled {
            quitFlow = .stopping(operations.keys.first, nil)
            try? await Task.sleep(for: .milliseconds(50))
        }
        for environment in environments where !Task.isCancelled {
            await refreshStatus(of: environment.id)
        }
    }

    /// Stops every running environment. `mode` is `.force` only for the environments whose
    /// graceful stop already failed: the rest are always asked to shut down first, so a
    /// second VM is never hard-stopped without being asked (MVP-PLAN.md §2).
    private func stopAll(mode: StopMode, generation: UInt64) async {
        // A retired attempt reaches here only after the sheet already answered AppKit; the
        // guard keeps it from resurrecting a failure over that answer, or over a newer Quit.
        guard generation == quitGeneration else { return }
        if Task.isCancelled || quitCancelRequested { finishCancel(reconcile: true); return }
        if let uncertain = uncertainEnvironments.first {
            quitFlow = .stopFailed(.vmOwnershipUncertain(uncertain.id))
            return
        }
        for environment in runningEnvironments {
            guard generation == quitGeneration else { return }
            if Task.isCancelled || quitCancelRequested { finishCancel(reconcile: true); return }
            let force = mode == .force && gracefulFailures.contains(environment.id)
            let effective: StopMode = force ? .force : .graceful(deadline: Self.gracefulStopDeadline)
            quitFlow = force ? .forceStopping(environment.id) : .stopping(environment.id, nil)
            // Only a stop the runtime took on can have failed gracefully. A request refused
            // before acceptance — a service still initializing answers `runtimeStarting`
            // without reaching the lifecycle — never asked the guest to shut down, so it must
            // not unlock the force-stop that MVP-PLAN.md §2 reserves for a refused shutdown.
            var accepted = false
            do {
                for try await event in backend.send(.stopEnvironment(environment.id, effective)) {
                    guard generation == quitGeneration else { return }
                    switch event {
                    case .accepted:
                        accepted = true
                    case .progress(_, let phase):
                        if case .stopping = quitFlow { quitFlow = .stopping(environment.id, phase) }
                    case .status(let status):
                        statuses[status.environmentID] = status
                    case .failed(_, let error):
                        if accepted { gracefulFailures.insert(environment.id) }
                        // A cancellation deferred by a protected phase is honored here too:
                        // the user asked to stay, and the outcome is now known.
                        if quitCancelRequested { finishCancel(reconcile: true); return }
                        quitFlow = .stopFailed(error)
                        return
                    default:
                        break
                    }
                }
            } catch {
                launchState = .interrupted(RuntimeConnectionInterrupted())
                guard generation == quitGeneration else { return }
                if quitCancelRequested { finishCancel(reconcile: true); return }
                quitFlow = .stopFailed(.operationOutcomeUnknown(OperationID()))
                return
            }
            gracefulFailures.remove(environment.id)
        }
        // A superseded attempt only stops here: cancelling would retire the Quit that replaced
        // it, clear its task and answer AppKit a second time.
        guard generation == quitGeneration else { return }
        // The user may have canceled while the last stop was finishing; AppKit is told to
        // terminate only when the decision still stands.
        guard !Task.isCancelled, !quitCancelRequested else { finishCancel(reconcile: true); return }
        quitFlow = .terminating
        terminationDecision(true)
    }
}

/// Holds a task so a main-actor object's `deinit` can cancel it without touching isolated state.
nonisolated private final class CancelOnDeinit: Sendable {
    private let storage = Mutex<Task<Void, Never>?>(nil)

    var task: Task<Void, Never>? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    func cancel() {
        storage.withLock { $0?.cancel() }
    }
}
