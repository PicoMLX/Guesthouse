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
        /// Waiting for an operation to finish before targets are chosen. Nothing has been
        /// asked of the runtime yet, so cancelling here is immediate.
        case waitingForOperations(EnvironmentID?)
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
        static let maximumLogLines = 500

        /// The app's own label for the operation until the runtime accepts it.
        var id: OperationID
        /// The runtime's id, known only after `accepted`; nothing is canceled by any other id.
        var acceptedID: OperationID?
        var request: RuntimeRequest
        var phase: ProgressPhase?
        /// Redacted lines the runtime reported for this operation, newest last, bounded.
        var logs: [RedactedLine] = []
    }

    static let gracefulStopDeadline: Duration = .seconds(60)

    private(set) var launchState: LaunchState = .checkingEnvironment
    private(set) var environments: [DevelopmentEnvironment] = []
    private(set) var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    private(set) var operations: [EnvironmentID: OperationState] = [:]
    /// The last failure per environment, cleared when an operation completes.
    /// Environments whose last status query failed, so a later success can clear that
    /// error without erasing what a failed operation reported.
    private var statusQueryFailures: Set<EnvironmentID> = []
    /// Orders the status inspections of one environment against each other: the next ticket to
    /// hand out, and the newest one whose reply has been published.
    private var statusQueryTickets: [EnvironmentID: UInt64] = [:]
    private var publishedStatusTicket: [EnvironmentID: UInt64] = [:]
    private(set) var lastErrors: [EnvironmentID: GuesthouseError] = [:]
    /// Operations whose connection dropped before a result arrived. Cleared only by a
    /// successful status query; Retry is never offered while an entry exists (MVP-PLAN.md §3).
    private(set) var unknownOutcomes: [EnvironmentID: OperationID] = [:]
    /// What Retry re-sends.
    private(set) var lastRequests: [EnvironmentID: RuntimeRequest] = [:]
    /// Environments whose post-operation status query is still outstanding: nothing is
    /// replayed until the actual state has been read (MVP-PLAN.md §9).
    private(set) var reconciling: Set<EnvironmentID> = []
    /// The log of the last finished operation, for the disclosure after it ends.
    private(set) var lastLogs: [EnvironmentID: [RedactedLine]] = [:]
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
    /// The one poll that follows operations only the runtime reports. Owned by the model, so
    /// every reconciliation replaces it instead of adding another.
    private var recoveredOperationPoll: Task<Void, Never>?
    /// How long that poll waits between inspections. The runtime runs a Tart command for each
    /// status query, so inspections are seconds apart rather than several times a second.
    var recoveredOperationPollInterval: Duration = .seconds(2)
    /// How many of those polls are running. The model owns one at a time, so this is 0 or 1.
    private(set) var recoveredOperationPolls = 0
    /// What the service reports about itself and the Tart bundle it verified. The per-status
    /// observation carries no Tart version, so this is where the dashboard's tool-version row
    /// comes from (MVP-PLAN.md §2).
    private(set) var runtimeVersion: RuntimeVersionInfo?
    /// How many inspections of an environment are still outstanding. A card tells a check that
    /// is running from one that already ended in failure, so a query nobody is waiting for is
    /// never presented as one still in progress.
    private var statusQueriesInFlight: [EnvironmentID: Int] = [:]
    /// The poll of operations only a status reports. Held so an inspection that discovers one
    /// joins the loop already running instead of stacking a second one on it.
    private var recoveredPollTask: Task<Void, Never>?

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
        case .ready(let listed, let fresh, let version):
            environments = listed
            statuses = fresh
            // Assigned whatever the supplementary request answered: a service that could not
            // describe itself this time has not confirmed the version it gave last time, and
            // the MVP-PLAN.md §2 tool-version row says Unknown rather than repeating a value
            // nothing verified.
            runtimeVersion = version
            // These environments answered, so a failure of an earlier *query* is history,
            // exactly as it is after a single successful status query. A failed operation's
            // error stays: it is what the card explains.
            for id in fresh.keys where statusQueryFailures.remove(id) != nil { lastErrors[id] = nil }
            launchState = .ready
            // A full reconciliation read every listed environment's status: those unknown
            // outcomes are settled here just as a per-card check would settle them.
            unknownOutcomes = unknownOutcomes.filter { fresh[$0.key] == nil }
            startRecoveredOperationPoll()
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
        case ready([DevelopmentEnvironment], [EnvironmentID: EnvironmentStatus], RuntimeVersionInfo?)
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
            // Supplementary: the environments were read, so a service that cannot describe
            // itself leaves the version row unknown rather than making the app unavailable.
            var version: RuntimeVersionInfo?
            for try await event in backend.send(.runtimeVersion) {
                if case .runtimeVersion(let info) = event { version = info }
            }
            return .ready(listed, fresh, version)
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
        case .checking, .waitingForOperations, .stopping, .forceStopping, .terminating:
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
        var parts: [String] = []
        let running = runningEnvironments.count
        if running > 0 { parts.append("\(running) running") }
        let uncertain = uncertainEnvironments.count
        if uncertain > 0 { parts.append("\(uncertain) development Mac\(uncertain == 1 ? "" : "s") Guesthouse cannot identify") }
        // An environment whose last check did not answer is not a stopped one either: leaving
        // it out would let one failed query report an unknown VM as "no development Mac
        // running", which is the same unproven claim uncertainty is kept out of.
        let unread = unreadEnvironments.count
        if unread > 0 { parts.append("\(unread) development Mac\(unread == 1 ? "" : "s") Guesthouse could not check") }
        return parts.isEmpty ? "No development Mac running" : parts.joined(separator: ", ")
    }

    /// What the Quit confirmation says about the state it is about to act on.
    ///
    /// Ownership the runtime could not establish is named here as it is in the menu bar, never
    /// folded into "no development Mac is running": that reports an unproven stopped state as
    /// fact, and this is the sentence the user's Quit-or-Cancel decision is made on. The stop
    /// itself refuses over an uncertain environment, so promising a clean quit here would be
    /// contradicted a moment later (MVP-PLAN.md §4).
    var quitConfirmationMessage: String {
        var sentences: [String] = []
        let running = runningEnvironments.count
        if running > 0 {
            sentences.append(running == 1
                ? "Quitting stops the running development Mac first."
                : "Quitting stops all running development Macs first.")
        }
        let uncertain = uncertainEnvironments.count
        if uncertain > 0 {
            sentences.append(uncertain == 1
                ? "Guesthouse cannot tell whether one development Mac is running, and cannot stop it until that is checked."
                : "Guesthouse cannot tell whether \(uncertain) development Macs are running, and cannot stop them until that is checked.")
        }
        // An environment whose last check did not answer is unproven in the same way, and this
        // is the sentence the Quit-or-Cancel decision is made on: reporting it as nothing
        // running would state a stopped VM as fact on the strength of a query that failed.
        let unread = unreadEnvironments.count
        if unread > 0 {
            sentences.append(unread == 1
                ? "One development Mac did not answer its last check, so Guesthouse cannot tell whether it is running."
                : "\(unread) development Macs did not answer their last check, so Guesthouse cannot tell whether they are running.")
        }
        return sentences.isEmpty ? "No development Mac is running." : sentences.joined(separator: " ")
    }

    /// Environments whose VM ownership the runtime could not establish. Neither stop mode is
    /// safe on them, so they block quitting until a check resolves them.
    var uncertainEnvironments: [DevelopmentEnvironment] {
        environments.filter {
            if case .uncertain = statuses[$0.id]?.vm { return true }
            return false
        }
    }

    /// Environments with no status at all: the last query for them failed or was lost. Nothing
    /// is known about their VM, which is not the same as knowing it is stopped.
    var unreadEnvironments: [DevelopmentEnvironment] {
        environments.filter { statuses[$0.id] == nil }
    }

    /// The runtime runs one lifecycle operation at a time and one VM at a time
    /// (MVP-PLAN.md §4, §6), so a start on any card is refused while another environment is
    /// running or any operation is in flight.
    var globalStartBlock: String? {
        if let busy = operations.keys.first ?? statuses.values.first(where: { $0.inFlightOperation != nil })?.environmentID,
           let name = environments.first(where: { $0.id == busy })?.name {
            return "An operation is in progress on \(name)."
        }
        // An operation whose outcome was never established may already have started its VM,
        // and an environment still being read back may be about to report one. Neither is a
        // state to start a second development Mac over (AGENTS.md: an interrupted operation
        // has an unknown outcome until the actual state is inspected).
        if let unknown = unknownOutcomes.keys.first, let name = environments.first(where: { $0.id == unknown })?.name {
            return "Guesthouse does not know yet what its last operation on \(name) did. Check that development Mac first."
        }
        if let checking = reconciling.first, let name = environments.first(where: { $0.id == checking })?.name {
            return "\(name) is being checked after its last operation."
        }
        // An environment that has not answered its last check says nothing about its VM or
        // about an operation on it. The runtime runs one VM and one operation at a time, so
        // nothing is started until it answers (MVP-PLAN.md §2).
        if let unread = environments.first(where: { statuses[$0.id] == nil }) {
            return "\(unread.name) has not answered its last check. Check it before starting another development Mac."
        }
        if let running = runningEnvironments.first {
            return "\(running.name) is running. Guesthouse runs one development Mac at a time until resource validation allows two."
        }
        // A VM the runtime cannot prove it owns is still a VM: the lifecycle refuses a second
        // one while it is there, so the dashboard says so rather than offering a start.
        if let uncertain = uncertainEnvironments.first {
            return "\(uncertain.name) is running without proof that Guesthouse started it. Check it before starting another development Mac."
        }
        return nil
    }

    /// Statuses that name an operation this app did not start (one recovered after a
    /// relaunch) are re-queried until they become terminal, so a card never stays busy for
    /// an operation nobody observes.
    func pollRecoveredOperations() async {
        recoveredOperationPolls += 1
        defer { recoveredOperationPolls -= 1 }
        while !Task.isCancelled {
            let recovered = statuses.values.filter { $0.inFlightOperation != nil && operations[$0.environmentID] == nil }.map(\.environmentID)
            if recovered.isEmpty { return }
            try? await Task.sleep(for: recoveredOperationPollInterval)
            // The wait swallows its own cancellation, so a poll being replaced would
            // otherwise still run one more round of queries against the runtime.
            guard !Task.isCancelled else { return }
            for id in recovered { await refreshStatus(of: id) }
        }
    }

    /// Replaces the poll rather than adding one: every reconciliation would otherwise leave
    /// another task inspecting the same operation, multiplying the Tart processes the runtime
    /// runs for each query until the session's in-flight limit refuses them.
    private func startRecoveredOperationPoll() {
        recoveredOperationPoll?.cancel()
        recoveredOperationPoll = Task { [weak self] in
            guard let self else { return }
            await self.pollRecoveredOperations()
        }
    }

    /// Follows an operation only the runtime reports, unless a poll is already doing so. The
    /// running poll re-reads `statuses` at the top of every round, so it picks this
    /// environment up on its own; starting another from inside the very inspection that poll
    /// is awaiting would cancel it mid-round instead.
    private func followRecoveredOperation(of id: EnvironmentID) {
        guard operations[id] == nil, statuses[id]?.inFlightOperation != nil, recoveredOperationPolls == 0 else { return }
        startRecoveredOperationPoll()
    }

    /// Re-reads one environment's status after an operation, whatever its outcome. A status
    /// query the runtime answers with a failure leaves no cached state behind: the card shows
    /// the error and offers nothing until a later query succeeds.
    /// Re-reads one environment's status after an operation, whatever its outcome. A
    /// successful answer settles an unknown outcome; a failed one leaves no cached state
    /// behind and keeps the outcome unknown: the card shows the error and offers nothing
    /// until a later query succeeds.
    func refreshStatus(of id: EnvironmentID) async {
        // The reconciliation this query started under. The client reports a dropped connection
        // to its observers before it throws into the streams that connection cut off, so a
        // reconciliation launched by that same loss can already have read the actual state by
        // the time the loss lands here.
        let generation = refreshGeneration
        // Two inspections of one environment can be in flight at once — the recovered-operation
        // poll and a Quit waiting on that same operation both ask for it — and the runtime runs
        // its own Tart inventory read for each, so the older reply can arrive last. Both carry
        // the same reconciliation generation, so only this ticket separates them: without it an
        // inspection that began while the VM was still stopped could land over the running
        // result that replaced it, and Quit would then find no target to stop and terminate
        // with a VM it just started (MVP-PLAN.md §2).
        let ticket = (statusQueryTickets[id] ?? 0) &+ 1
        statusQueryTickets[id] = ticket
        statusQueriesInFlight[id, default: 0] += 1
        defer {
            let outstanding = (statusQueriesInFlight[id] ?? 1) - 1
            statusQueriesInFlight[id] = outstanding > 0 ? outstanding : nil
        }
        do {
            var received = false
            for try await event in backend.send(.environmentStatus(id)) {
                // A reconciliation that began after this query did has read the actual state
                // since, so its snapshot stands: an inspection that started while the VM was
                // running must not publish that over a newer stopped result and leave Start
                // blocked until someone checks again. The stream is drained rather than
                // dropped so the request still ends on the service. The catch below makes the
                // same check for a query that never answered.
                guard generation == refreshGeneration, ticket >= publishedStatusTicket[id] ?? 0 else { continue }
                publishedStatusTicket[id] = ticket
                switch event {
                case .status(let status):
                    statuses[id] = status
                    received = true
                    // The environment answered, so a failure of an earlier *query* is history.
                    // A failed operation's error stays: it is what the card explains.
                    if statusQueryFailures.remove(id) != nil { lastErrors[id] = nil }
                    // A poll whose own inspection failed ended without anything to restart it,
                    // so this is where an operation only the runtime reports is picked up
                    // again: without it the card stays busy and blocks every start until the
                    // user checks by hand (AGENTS.md: an interrupted operation's outcome is
                    // unknown until the state is inspected).
                    followRecoveredOperation(of: id)
                case .failed(_, let error):
                    statuses[id] = nil
                    lastErrors[id] = error
                    statusQueryFailures.insert(id)
                default: break
                }
            }
            // Only an actual status answer settles an unknown outcome; a failed or empty
            // reply leaves it unknown.
            if received { unknownOutcomes[id] = nil }
            // The answer may name an operation nobody is streaming (the original event stream
            // was lost, or it was started before this launch). It is polled from here, so a
            // card never stays busy for an operation that has since finished.
            if statuses[id]?.inFlightOperation != nil, operations[id] == nil { startRecoveredOperationPoll() }
        } catch {
            // A reconciliation that began after this query did has read the actual state
            // since, so its result stands: replacing it here would delete the status it just
            // established and put the app back on Interrupted over a Ready it disproved. A
            // newer inspection of this environment stands for the same reason.
            guard generation == refreshGeneration, ticket >= publishedStatusTicket[id] ?? 0 else { return }
            publishedStatusTicket[id] = ticket
            // The query never answered. What was cached says nothing about the VM now, and
            // Quit must not choose stop targets from it: the status is dropped and the
            // environment is marked as unanswered, exactly as a failed reply would.
            statuses[id] = nil
            statusQueryFailures.insert(id)
            launchState = .interrupted(RuntimeConnectionInterrupted())
        }
    }

    /// Clears the failure a card is showing and re-reads the environment. An error whose only
    /// recovery is `.cancel` — a start refused because another development Mac was running —
    /// has nothing else to offer, and a successful status query deliberately keeps operation
    /// errors, so without this the card would keep a stale refusal and its disabled Start until
    /// the app was relaunched (AGENTS.md: every error carries a recovery action that works).
    func dismissError(_ id: EnvironmentID) {
        lastErrors[id] = nil
        statusQueryFailures.remove(id)
        Task { await refreshStatus(of: id) }
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
                statusUnread: statuses[environment.id] == nil,
                statusCheckFailed: statusQueryFailures.contains(environment.id) && statusQueriesInFlight[environment.id] == nil,
                unknownOutcome: unknownOutcomes[environment.id],
                reconciling: reconciling.contains(environment.id),
                logs: operations[environment.id]?.logs ?? lastLogs[environment.id] ?? [],
                retryAvailable: lastRequests[environment.id] != nil && !reconciling.contains(environment.id),
                retryBlockedReason: startRetryBlock(for: environment.id, block: block),
                startBlockedElsewhere: (operations[environment.id] == nil && statuses[environment.id]?.vm != .running) ? block : nil,
                runtimeVersion: runtimeVersion
            )
        }
    }

    /// Why replaying the last request would be refused, or nil. Retry re-sends whatever
    /// failed, so a replayed start answers to the same one-VM, one-operation guard as Start
    /// itself, and the card names the environment that is in the way rather than sending a
    /// request the runtime must reject.
    private func startRetryBlock(for id: EnvironmentID, block: String?) -> String? {
        guard case .startEnvironment? = lastRequests[id] else { return nil }
        return block
    }

    /// Asks the runtime to cancel the environment's in-flight operation.
    /// Asks the runtime to cancel the environment's in-flight operation: the one this app
    /// started once the runtime has accepted it, or the one a status reported after a
    /// relaunch. A cancellation the runtime refuses is shown like any other failure.
    func cancel(_ id: EnvironmentID) {
        guard let operation = operations[id]?.acceptedID ?? statuses[id]?.inFlightOperation else { return }
        Task {
            do {
                for try await event in backend.send(.cancelOperation(operation)) {
                    if case .failed(_, let error) = event { lastErrors[id] = error }
                }
            } catch {
                launchState = .interrupted(RuntimeConnectionInterrupted())
            }
        }
    }

    /// The recovery actions the GUI wires: retry re-sends the last request (never while the
    /// outcome is unknown), inspect re-reads the status, cancel dismisses the failure. The
    /// rest are shown as not implemented by the view.
    func perform(_ action: RecoveryAction, for id: EnvironmentID) {
        switch action {
        case .retry:
            guard unknownOutcomes[id] == nil, operations[id] == nil, !reconciling.contains(id), let request = lastRequests[id] else { return }
            // A replayed start is one more start: the runtime still runs one operation and one
            // VM at a time, and sending past that would replace the useful original error.
            if case .startEnvironment = request, globalStartBlock != nil { return }
            // Reserved before the first suspension, so two rapid activations of Try again —
            // or a Start pressed straight after it — cannot both pass this guard.
            operations[id] = OperationState(id: OperationID(), request: request)
            Task { await run(request, for: id) }
        case .inspectState:
            Task { await refreshStatus(of: id) }
        case .cancel:
            lastErrors[id] = nil
        default:
            break
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
        // A reconciliation in progress, or one that lost its connection, leaves the previous
        // statuses cached, and the cached snapshot is what `globalStartBlock` reads: a Start
        // rendered a moment before the state changed could otherwise send a mutating request
        // over state nothing has re-established. Nothing is started until reconciliation has
        // (AGENTS.md: never retry a mutating operation blindly).
        guard launchState == .ready else { return }
        guard environments.contains(where: { $0.id == id }), operations[id] == nil,
              !reconciling.contains(id), globalStartBlock == nil else { return }
        // Reserved before the first suspension, so two rapid starts cannot both pass the guard.
        operations[id] = OperationState(id: OperationID(), request: .startEnvironment(id, StartOptions()))
        Task { await run(.startEnvironment(id, StartOptions()), for: id) }
    }

    /// Records what an operation itself reported for `id`. The result supersedes any earlier
    /// status-query failure: left standing, that marker would let the next successful query
    /// clear this error as if it were the stale one, and the card would lose the recovery the
    /// operation's own failure prescribes.
    private func recordOperationError(_ error: GuesthouseError?, for id: EnvironmentID) {
        lastErrors[id] = error
        statusQueryFailures.remove(id)
    }

    private func run(_ request: RuntimeRequest, for id: EnvironmentID) async {
        recordOperationError(nil, for: id)
        // The reconciliation this stream started under. The client reports a dropped
        // connection to its observers before it throws into the streams that connection cut
        // off, so a reconciliation launched by that same loss can already have read the
        // actual state by the time this stream ends.
        let generation = refreshGeneration
        lastRequests[id] = request
        if operations[id] == nil { operations[id] = OperationState(id: OperationID(), request: request) }
        var completed = false
        var described = false
        do {
            for try await event in backend.send(request) {
                switch event {
                case .accepted(let operation): operations[id]?.acceptedID = operation
                case .progress(_, let phase): operations[id]?.phase = phase
                case .log(_, let line):
                    operations[id]?.logs.append(line)
                    if let count = operations[id]?.logs.count, count > OperationState.maximumLogLines {
                        operations[id]?.logs.removeFirst(count - OperationState.maximumLogLines)
                    }
                case .status(let status):
                    statuses[status.environmentID] = status
                    if status.environmentID == id { described = true }
                case .failed(_, let error): recordOperationError(error, for: id)
                case .completed:
                    recordOperationError(nil, for: id)
                    completed = true
                    // The request succeeded, so it is no longer what Try again would replay: a
                    // problem a later status reports on its own must not re-send this one.
                    lastRequests[id] = nil
                default: break
                }
            }
        } catch {
            // The outcome is unknown until the runtime is asked again; never replay. A
            // reconciliation that began after this stream did has looked at the actual state
            // since, so its result stands rather than being overwritten by this loss.
            if generation == refreshGeneration { launchState = .interrupted(RuntimeConnectionInterrupted()) }
            // The outcome is unknown until the runtime answers a status query; never replay.
            // Before acceptance the app's own label stands in: the runtime may or may not
            // have received the request.
            unknownOutcomes[id] = operations[id]?.acceptedID ?? operations[id]?.id
        }
        // A start that failed or was lost may already have launched the VM, so what was cached
        // before it says nothing about the state now. Nor does it after one that completed
        // without describing the environment: the runtime's own status refresh after a stop or
        // a start is a bounded courtesy and can time out, leaving the pre-start `.stopped`
        // behind. Either way the status is dropped before the reservation is released, because
        // an actionable `.stopped` would re-enable Start here and on every other card for the
        // seconds the inspection below takes, and let a second mutation go out over a VM that
        // is already running (AGENTS.md: never retry a mutating operation blindly).
        if !completed || !described { statuses[id] = nil }
        lastLogs[id] = operations.removeValue(forKey: id)?.logs
        reconciling.insert(id)
        // A status that still names an operation (the connection dropped while the runtime
        // kept working) is polled until it settles; `refreshStatus` starts that itself.
        await refreshStatus(of: id)
        reconciling.remove(id)
        // The runtime may still be running the operation this app stopped listening to. A
        // reconciliation that ran while the operation was still local started a poll that found
        // nothing to follow and ended at once, so this handoff — from an operation this app
        // owned to one only the runtime reports — is where that poll has to be started again.
        // Without it the card stays busy and every start stays blocked until the user checks.
        followRecoveredOperation(of: id)
    }

    /// A model over a preview scenario's environments and scripted backend, already refreshed.
    static func preview(_ scenario: PreviewScenario) async -> AppModel {
        await scenario.backend.setEnvironments(scenario.snapshot.environments)
        let model = AppModel(backend: scenario.backend) { _ in }
        await model.refresh()
        if let request = scenario.initialRequest, case .startEnvironment(let id, _) = request {
            // A preview's seeded status may already name the operation, which the dashboard's
            // own guard would refuse; the scripted stream is attached to it regardless so the
            // progress UI has something to show. The guard itself is covered by tests.
            Task { await model.run(request, for: id) }
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
        case .waitingForOperations:
            // Nothing has been asked of the runtime yet, so the quit is simply abandoned.
            quitTask?.cancel()
            finishCancel(reconcile: true)
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
        guard await waitForOperations(generation: generation) else { return }
        guard generation == quitGeneration, !Task.isCancelled, !quitCancelRequested else { finishCancel(reconcile: true); return }
        // The mode still decides how they are stopped: only the environments whose graceful
        // stop already failed are force-stopped.
        quitFlow = mode == .force ? .forceStopping(nil) : .stopping(nil, nil)
        await stopAll(mode: mode, generation: generation)
    }

    /// Waits until neither this app nor the runtime reports an operation in flight: a start
    /// this app made moments ago, or one recovered after a relaunch that only the status
    /// names, must reach a terminal state before stop targets are chosen.
    /// Waits until neither this app nor the runtime reports an operation in flight. A status
    /// query that fails ends the wait: the quit stops rather than choosing targets from state
    /// nobody could read. Returns false when the quit must not continue.
    private func waitForOperations(generation: UInt64) async -> Bool {
        while !Task.isCancelled {
            for environment in environments {
                await refreshStatus(of: environment.id)
                // Each inspection is a suspension the user can cancel across, and a cancelled
                // attempt has already answered AppKit: it must not reopen the sheet on a
                // failure, nor speak for the Quit that replaced it.
                guard generation == quitGeneration else { return false }
                guard statuses[environment.id] != nil else {
                    quitFlow = .stopFailed(lastErrors[environment.id] ?? .operationOutcomeUnknown(OperationID()))
                    return false
                }
            }
            // An operation the app never saw finish may have started a VM this quit would
            // then leave running. The status queries above settle every outcome they can
            // answer; one that is still open stops the quit and asks for a check instead.
            if let unknown = unknownOutcomes.first {
                quitFlow = .stopFailed(.operationOutcomeUnknown(unknown.value))
                return false
            }
            let busy = operations.keys.first ?? statuses.values.first(where: { $0.inFlightOperation != nil })?.environmentID
            guard let busy else { return true }
            quitFlow = .waitingForOperations(busy)
            // The runtime runs a Tart command for every status query, so this waits in
            // seconds rather than polling several times a second.
            try? await Task.sleep(for: .seconds(2))
        }
        return false
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
