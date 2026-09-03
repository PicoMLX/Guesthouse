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
        case forceStopping(EnvironmentID?)
        /// Everything stopped; AppKit has been told to terminate.
        case terminating
    }

    static let gracefulStopDeadline: Duration = .seconds(60)

    private(set) var launchState: LaunchState = .checkingEnvironment
    private(set) var environments: [DevelopmentEnvironment] = []
    private(set) var statuses: [EnvironmentID: EnvironmentStatus] = [:]
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
    /// Set when a reconciliation ended `unavailable`: further connection drops no longer
    /// reconnect on their own, so the app stays on the recovery the error prescribes.
    private var automaticReconciliationSuspended = false
    /// The idle-loss observation; canceled from `deinit`, which is not actor-isolated.
    private let interruptionObservation = CancelOnDeinit()
    /// Bumped by every `refresh()`; a refresh whose generation is no longer current does not
    /// publish its result.
    private var refreshGeneration: UInt64 = 0

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

    /// Picks the real client, or the fake when `GUESTHOUSE_FAKE_RUNTIME=1` or when the app is
    /// hosting unit tests, so a test run never launches the runtime service.
    static func makeBackend(environment: [String: String] = ProcessInfo.processInfo.environment) -> any RuntimeBackend {
        if environment["GUESTHOUSE_FAKE_RUNTIME"] == "1" || environment["XCTestConfigurationFilePath"] != nil {
            return FakeRuntimeBackend()
        }
        return RuntimeClient()
    }

    // MARK: - Reconciliation

    /// Re-reads everything from the runtime. Never trusts a cached Ready: a refresh that was
    /// canceled or overtaken by a newer one publishes nothing, leaving "Checking environment"
    /// to the refresh that replaced it.
    /// Starts a reconciliation owned by the model. A window that closes cannot cancel it, so
    /// the menu bar and any surviving window still leave "Checking environment".
    func startRefresh() {
        automaticReconciliationSuspended = false
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        launchState = .checkingEnvironment
        let outcome = await reconcile()
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        switch outcome {
        case .ready(let listed, let fresh):
            environments = listed
            statuses = fresh
            launchState = .ready
        case .unavailable(let error):
            launchState = .unavailable(error)
            // An unavailable runtime is not something reconnecting fixes: the error carries
            // its own recovery, and the app stays on it until the user asks again.
            automaticReconciliationSuspended = true
        case .interrupted(let interruption):
            launchState = .interrupted(interruption)
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
        case .confirming, .stopFailed:
            // The sheet is open on state that is now stale: nothing is offered again until
            // the environments have been read back.
            quitGeneration &+= 1
            quitFlow = .checking
            let generation = quitGeneration
            quitTask = Task { [weak self] in
                guard let self else { return }
                await self.reconcileForQuit(generation: generation)
            }
        case .checking, .stopping, .forceStopping, .terminating:
            // A stop stream reports its own loss; nothing to do here.
            return
        }
        launchState = .interrupted(interruption)
        guard !automaticReconciliationSuspended else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    /// Re-reads the environments for an interrupted Quit sheet and returns it to its options,
    /// or shows why it could not.
    private func reconcileForQuit(generation: UInt64) async {
        await refresh()
        guard generation == quitGeneration, case .checking = quitFlow else { return }
        quitFlow = launchState == .ready ? .confirming : .stopFailed(launchStateError())
    }

    var runningEnvironments: [DevelopmentEnvironment] {
        environments.filter { statuses[$0.id]?.vm == .running }
    }

    /// Environments whose VM ownership the runtime could not establish. Neither stop mode is
    /// safe on them, so they block quitting until a check resolves them.
    var uncertainEnvironments: [DevelopmentEnvironment] {
        environments.filter {
            if case .uncertain = statuses[$0.id]?.vm { return true }
            return false
        }
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
    /// outcome, uncertain ownership) is checked first, never forced past.
    var canForceStop: Bool {
        guard case .stopFailed(let error) = quitFlow else { return false }
        switch error {
        case .operationOutcomeUnknown, .vmOwnershipUncertain: return false
        default: return error.recoveryActions.contains(.retry)
        }
    }

    /// The user accepted the force-stop warning.
    func forceStopAndQuit() {
        guard canForceStop else { return }
        quitCancelRequested = false
        quitGeneration &+= 1
        let generation = quitGeneration
        quitFlow = .forceStopping(nil)
        quitTask = Task { await stopAll(mode: .force, generation: generation) }
    }

    /// After an unknown outcome or uncertain ownership the sheet offers a check: reconcile, then
    /// return to the confirmation with the real state, or show why the check failed.
    func inspectAndContinueQuit() {
        guard case .stopFailed = quitFlow, !canForceStop else { return }
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
            // A stop the runtime has accepted but not yet described may already be in a
            // phase it will not interrupt; the cancellation waits for its outcome.
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
        case .stopping, .stopFailed:
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
        if reconcile { Task { await refresh() } }
    }

    private func launchStateError() -> GuesthouseError {
        if case .unavailable(let error) = launchState { return error }
        return .operationOutcomeUnknown(OperationID())
    }

    /// Stop targets come from reconciled state, never from what was cached before the sheet.
    private func stopAllAfterReconciling(mode: StopMode, generation: UInt64) async {
        if launchState != .ready {
            await refresh()
            guard generation == quitGeneration, case .checking = quitFlow else { return }
            guard launchState == .ready else {
                quitFlow = .stopFailed(launchStateError())
                return
            }
            quitFlow = .stopping(nil, nil)
        }
        // An operation the runtime still reports is unresolved, whatever the VM state says:
        // quitting over it could leave a VM the app never saw start.
        if let busy = statuses.values.first(where: { $0.inFlightOperation != nil }), let operation = busy.inFlightOperation {
            quitFlow = .stopFailed(.operationOutcomeUnknown(operation))
            return
        }
        await stopAll(mode: mode, generation: generation)
    }

    /// Stops every running environment. `mode` is `.force` only for the environments whose
    /// graceful stop already failed: the rest are always asked to shut down first, so a
    /// second VM is never hard-stopped without being asked (MVP-PLAN.md §2).
    private func stopAll(mode: StopMode, generation: UInt64) async {
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
            do {
                for try await event in backend.send(.stopEnvironment(environment.id, effective)) {
                    guard generation == quitGeneration else { return }
                    switch event {
                    case .progress(_, let phase):
                        if case .stopping = quitFlow { quitFlow = .stopping(environment.id, phase) }
                    case .status(let status):
                        statuses[status.environmentID] = status
                    case .failed(_, let error):
                        gracefulFailures.insert(environment.id)
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
                if quitCancelRequested { finishCancel(reconcile: true); return }
                quitFlow = .stopFailed(.operationOutcomeUnknown(OperationID()))
                return
            }
            gracefulFailures.remove(environment.id)
        }
        // The user may have canceled while the last stop was finishing; AppKit is told to
        // terminate only when the decision still stands.
        guard generation == quitGeneration, !Task.isCancelled, !quitCancelRequested else { finishCancel(reconcile: true); return }
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
