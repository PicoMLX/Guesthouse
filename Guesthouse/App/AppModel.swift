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
    /// The failure of an environment's last status query, so a later success can clear that
    /// error without erasing what a failed operation reported, and so the card can tell the
    /// check's own failure from a problem the environment reported.
    private var statusQueryFailures: [EnvironmentID: GuesthouseError] = [:]
    private(set) var lastErrors: [EnvironmentID: GuesthouseError] = [:]
    /// How the last operation this app sent for an environment failed, kept apart from the
    /// error a status query leaves on the card. The check that must follow a failed operation
    /// is allowed to fail too, and its error replaces the operation's in `lastErrors`; without
    /// this the bundle would name that check rather than the start or stop the user is
    /// reporting, and would carry the check's recovery actions instead of the operation's.
    private var operationFailures: [EnvironmentID: GuesthouseError] = [:]
    /// Operations whose connection dropped before a result arrived. Cleared only by a
    /// successful status query; Retry is never offered while an entry exists (MVP-PLAN.md §3).
    private(set) var unknownOutcomes: [EnvironmentID: OperationID] = [:]
    /// What Retry re-sends.
    private(set) var lastRequests: [EnvironmentID: RuntimeRequest] = [:]
    /// The generation of the last full reconciliation that succeeded. An operation stream cut
    /// off before it ended asks this whether the state it would call unknown has in fact been
    /// read back since (AGENTS.md: inspected, not assumed).
    private var reconciledGeneration: UInt64 = 0
    /// Environments whose post-operation status query is still outstanding: nothing is
    /// replayed until the actual state has been read (MVP-PLAN.md §9).
    private(set) var reconciling: Set<EnvironmentID> = []
    /// The log of the last finished operation, for the disclosure after it ends.
    private(set) var lastLogs: [EnvironmentID: [RedactedLine]] = [:]
    /// What the service reports about itself and the Tart bundle it verified. The per-status
    /// observation carries no Tart version, so this is where the dashboard's tool-version row
    /// and the diagnostics bundle's metadata come from (MVP-PLAN.md §2).
    private(set) var runtimeInfo: RuntimeVersionInfo?
    private let redactor = Redactor()
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
    /// How long the quit waits between re-inspections of an operation it is blocked on. Same
    /// reasoning as the poll above, and settable so a test never has to wait real seconds.
    var quitWaitPollInterval: Duration = .seconds(2)
    /// How many of those polls are running. The model owns one at a time, so this is 0 or 1.
    private(set) var recoveredOperationPolls = 0
    /// How many inspections of an environment are still outstanding. A card tells a check that
    /// is running from one that already ended in failure, so a query nobody is waiting for is
    /// never presented as one still in progress.
    private var statusQueriesInFlight: [EnvironmentID: Int] = [:]
    /// The poll of operations only a status reports. Held so an inspection that discovers one
    /// joins the loop already running instead of stacking a second one on it.
    private var recoveredPollTask: Task<Void, Never>?
    /// A cancellation the runtime refused, with the operation it was for. An answer that
    /// arrives after that operation has ended is not news, and one that stands is cleared
    /// when an inspection shows the operation is over.
    private var cancellationFailures: [EnvironmentID: CancellationFailure] = [:]
    /// Bumped by every inspection of an environment *and by every full reconciliation that
    /// publishes*; an answer from a superseded inspection publishes nothing, so an older
    /// status can never replace a newer one, whichever path read it.
    private var statusGenerations: [EnvironmentID: UInt64] = [:]
    /// The inspection currently reading each environment, so the one it replaces can be
    /// cancelled rather than left suspended on a stream that may never answer.
    private var statusRequests: [EnvironmentID: Task<Void, Never>] = [:]

    private struct CancellationFailure {
        let operation: OperationID
        let error: GuesthouseError
    }

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
        if let loss = lossLeftToReconciliation, case .ready(_, _, let version) = outcome {
            // The version this reconciliation did read is still what diagnostics should report:
            // the loss is about the session, not about what the runtime said of itself.
            settled = .interrupted(loss, version)
        }
        lossLeftToReconciliation = nil
        switch settled {
        case .ready(let listed, let read, let version):
            environments = listed
            // A full reconciliation reads every environment's status, so it is an inspection
            // like any other and joins the same generation scheme — but per entry, claimed
            // where each status was read rather than where the whole snapshot is published.
            // The snapshot is assembled over several round trips: the listing, one status per
            // environment, then the version. An inspection that answered while this one was
            // still waiting on a later environment has read the state more recently than the
            // entry collected here, and publishing the snapshot wholesale put its settled
            // operation back in flight and blocked Start and Quit until someone checked again.
            var published: [EnvironmentID: EnvironmentStatus] = [:]
            for environment in listed {
                let id = environment.id
                if let entry = read[id], statusGenerations[id] == entry.generation {
                    published[id] = entry.status
                } else if let newer = statuses[id] {
                    published[id] = newer
                }
            }
            // An environment the listing no longer names is described by nothing, so an
            // inspection still outstanding for it must not publish over that.
            let listedIDs = Set(listed.map(\.id))
            for id in Array(statusGenerations.keys) where !listedIDs.contains(id) {
                _ = claimStatusGeneration(of: id)
            }
            statuses = published
            // Assigned whatever the supplementary request answered, and only now, with the
            // rest of this refresh's result: a service that could not describe itself this
            // time has not confirmed the version it gave last time, so the tool-version row
            // says Unknown rather than repeating a value nothing verified, and an overtaken
            // reconciliation cannot change the metadata diagnostics report.
            runtimeInfo = version
            // These environments answered, so a failure of an earlier *query* is history,
            // exactly as it is after a single successful status query. A failed operation's
            // error stays: it is what the card explains.
            for id in published.keys where statusQueryFailures.removeValue(forKey: id) != nil { lastErrors[id] = nil }
            launchState = .ready
            // A full reconciliation read every listed environment's status, so it settles
            // exactly what a per-card check settles: an unknown outcome, a reconciliation
            // marker, and a refused cancellation whose operation has since ended. Anything
            // these statuses did not answer for keeps its marker.
            for (id, status) in published { settle(status, for: id) }
            // The state every listed environment was in has now been read back. An operation
            // stream that was cut off before this consults it rather than restoring an unknown
            // outcome over an inspection that has already happened.
            reconciledGeneration = generation
            startRecoveredOperationPoll()
        case .unavailable(let error, let version):
            // Assigned whole, including a nil: a request rejected before it returned metadata
            // has no current version to publish, and keeping the last verified one would have
            // diagnostics report a runtime that is not the one that just failed.
            runtimeInfo = version
            launchState = .unavailable(error)
            // An unavailable runtime is not something reconnecting fixes: the error carries
            // its own recovery, and the app stays on it until the user asks again.
            automaticReconciliationSuspended = true
        case .interrupted(let interruption, let version):
            // Assigned whole, including a nil, for the same reason as above: the session that
            // answered the last version is the one that just dropped, so keeping its answer
            // would have diagnostics describe a runtime beside a connection failure this
            // refresh never got past. What this refresh did read before the loss stands.
            runtimeInfo = version
            launchState = .interrupted(interruption)
            // A reconciliation that was itself cut off would otherwise be restarted by the
            // loss it just suffered, relaunching a service that keeps crashing forever. The
            // interruption recovery stays on screen until the user asks for another check.
            automaticReconciliationSuspended = true
        }
    }

    /// One environment's status as a reconciliation read it, with the generation that read
    /// claimed. How fresh an entry is belongs to the entry, not to the moment the snapshot
    /// it is part of happens to be published.
    private struct ReadStatus {
        let status: EnvironmentStatus
        let generation: UInt64
    }

    private enum ReconcileOutcome {
        case ready([DevelopmentEnvironment], [EnvironmentID: ReadStatus], RuntimeVersionInfo?)
        /// The runtime answered its version and then could not be used. The version is
        /// carried anyway: diagnostics must describe the runtime as it is now, not as the
        /// last successful check left it.
        case unavailable(GuesthouseError, RuntimeVersionInfo?)
        /// The connection dropped mid-reconciliation. The version is carried for the same
        /// reason: whatever this refresh read before the loss is the current metadata, and
        /// what it never read is not.
        case interrupted(RuntimeConnectionInterrupted, RuntimeVersionInfo?)
    }

    private func reconcile() async -> ReconcileOutcome {
        // Declared outside the attempt so an interrupted reconciliation reports what it did
        // read: the alternative is publishing the previous session's version beside the
        // failure of this one.
        var version: RuntimeVersionInfo?
        do {
            // Asked first, so a listing that fails afterwards still names the runtime the
            // diagnostics bundle reports. This request is supplementary: a service that cannot
            // describe itself still works, and the tool-version row says Unknown rather than
            // taking the whole app down. A protocol mismatch is the exception, because it is a
            // fact about the session rather than about this request — nothing else this app
            // sends will be understood — so it reports the runtime as unavailable with the
            // recovery that error carries.
            for try await event in backend.send(.runtimeVersion) {
                switch event {
                case .runtimeVersion(let info): version = info
                case .failed(_, let error):
                    if case .protocolMismatch = error { return .unavailable(error, version) }
                default: break
                }
            }
            var listed: [DevelopmentEnvironment] = []
            for try await event in backend.send(.listEnvironments) {
                switch event {
                case .environments(let environments): listed = environments
                case .failed(_, let error): return .unavailable(error, version)
                default: break
                }
            }
            var fresh: [EnvironmentID: ReadStatus] = [:]
            for environment in listed {
                let generation = claimStatusGeneration(of: environment.id)
                for try await event in backend.send(.environmentStatus(environment.id)) {
                    if case .status(let status) = event {
                        fresh[environment.id] = ReadStatus(status: status, generation: generation)
                    }
                    if case .failed(_, let error) = event { return .unavailable(error, version) }
                }
            }
            return .ready(listed, fresh, version)
        } catch let error as RuntimeConnectionInterrupted {
            return .interrupted(error, version)
        } catch {
            return .interrupted(RuntimeConnectionInterrupted(), version)
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
        if let unknown = environmentsWithUnknownOutcome.first {
            // An environment the runtime has since stopped listing keeps its marker: the
            // mutation may still be running, so the block stands with a name or without one.
            guard let name = environments.first(where: { $0.id == unknown })?.name else {
                return "Guesthouse does not know yet what its last operation did. Check the development Macs before starting another."
            }
            return "Guesthouse does not know yet what its last operation on \(name) did. Check that development Mac first."
        }
        if let checking = reconciling.first {
            // An environment the runtime has since stopped listing keeps its entry, exactly as
            // an unknown outcome does: its VM state was never established, so the block stands
            // with a name or without one. Requiring the name here would let a start on a
            // listed environment through while an unlisted one was still unaccounted for.
            guard let name = environments.first(where: { $0.id == checking })?.name else {
                return "Guesthouse is still checking a development Mac after its last operation."
            }
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

    /// Environments whose last mutation has no established outcome: one whose stream this app
    /// lost, and one the runtime itself reports as unresolved. The runtime runs one VM and one
    /// operation at a time, so neither is a state to start a second development Mac over
    /// (AGENTS.md: an interrupted operation has an unknown outcome until the actual state is
    /// inspected).
    private var environmentsWithUnknownOutcome: [EnvironmentID] {
        let reported = statuses.values.compactMap { status -> EnvironmentID? in
            Self.reportedUnknownOutcome(of: status) != nil ? status.environmentID : nil
        }
        return Array(unknownOutcomes.keys) + reported.filter { unknownOutcomes[$0] == nil }
    }

    /// The operation a status itself reports as unresolved, if it does.
    private static func reportedUnknownOutcome(of status: EnvironmentStatus?) -> OperationID? {
        if case .needsAttention(.operationOutcomeUnknown(let operation))? = status?.readiness { return operation }
        return nil
    }

    /// The mutation whose outcome is still open for `id`: the one this app lost the stream to,
    /// or the one the runtime is reporting as unresolved on its own.
    private func unresolvedOperation(of id: EnvironmentID) -> OperationID? {
        unknownOutcomes[id] ?? Self.reportedUnknownOutcome(of: statuses[id])
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
            // An inspection somebody else already has outstanding answers the same question
            // this poll asks, so the poll waits for it rather than replacing it. A quit's own
            // wait loop inspects the same environments on the same interval; two loops that
            // each cancel the other's request would leave a query slower than the interval
            // cancelled before it ever answered, and cancelling the consumer does not withdraw
            // the request from the service, which holds one of its eight in-flight slots until
            // it replies. An explicit check still supersedes, so a hung inspection is still
            // replaceable.
            for id in recovered where statusRequests[id] == nil { await refreshStatus(of: id) }
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
        // Two activations of Check environment are two requests, and the runtime may answer
        // them out of order: only the newest inspection may publish, so a stale status can
        // never replace a newer one or re-block the dashboard behind it.
        let generation = claimStatusGeneration(of: id)
        let request = Task { [weak self] in
            guard let self else { return }
            await self.readStatus(of: id, generation: generation)
        }
        statusRequests[id] = request
        // The caller's own cancellation still reaches the request: `waitForOperations` relies
        // on a cancelled quit ending the inspection it is suspended on.
        await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
        if statusRequests[id] == request { statusRequests[id] = nil }
    }

    /// Claims the next inspection generation for one environment and retires the inspection it
    /// supersedes.
    ///
    /// The claim comes first, so the request being superseded already reads a newer generation
    /// when its cancellation lands and cannot report an interruption over the one replacing it.
    /// A generation check alone discards a late answer but does nothing about a request that
    /// never answers: a hung `environmentStatus` stream stays suspended holding one of the
    /// session's eight in-flight slots, its `statusRequests` entry stands for the life of the
    /// session, and `pollRecoveredOperations` skips an environment whose inspection is already
    /// outstanding — so an operation only the runtime reports would never be seen to end and
    /// the card would stay busy with every action blocked.
    private func claimStatusGeneration(of id: EnvironmentID) -> UInt64 {
        let generation = (statusGenerations[id] ?? 0) &+ 1
        statusGenerations[id] = generation
        statusRequests[id]?.cancel()
        return generation
    }

    private func readStatus(of id: EnvironmentID, generation: UInt64) async {
        // The reconciliation this inspection started under. A full check reads every
        // environment, so one that began later has newer state than this per-card query: its
        // result stands, and this one publishes nothing over it.
        let atRefresh = refreshGeneration
        // Counted around the query itself, so a card can tell a check that is running from one
        // that already ended in failure and never presents a finished query as one in progress.
        statusQueriesInFlight[id, default: 0] += 1
        defer {
            let outstanding = (statusQueriesInFlight[id] ?? 1) - 1
            statusQueriesInFlight[id] = outstanding > 0 ? outstanding : nil
        }
        do {
            var received = false
            for try await event in backend.send(.environmentStatus(id)) {
                // A newer inspection has read the actual state since, so its snapshot stands: a
                // query that started while the VM was running must not publish that over a newer
                // stopped result and leave Start blocked until someone checks again. The stream
                // is drained rather than dropped so the request still ends on the service. The
                // catch below makes the same check for a query that never answered.
                guard statusGenerations[id] == generation, atRefresh == refreshGeneration else { continue }
                switch event {
                case .status(let status):
                    statuses[id] = status
                    received = true
                    // The environment answered, so a failure of an earlier *query* is history.
                    // A failed operation's error stays: it is what the card explains.
                    if statusQueryFailures.removeValue(forKey: id) != nil { lastErrors[id] = nil }
                    // A poll whose own inspection failed ended without anything to restart it,
                    // so this is where an operation only the runtime reports is picked up
                    // again: without it the card stays busy and blocks every start until the
                    // user checks by hand (AGENTS.md: an interrupted operation's outcome is
                    // unknown until the state is inspected).
                    followRecoveredOperation(of: id)
                case .failed(_, let error):
                    statuses[id] = nil
                    lastErrors[id] = error
                    statusQueryFailures[id] = error
                    cancellationFailures[id] = nil
                default: break
                }
            }
            guard statusGenerations[id] == generation else { return }
            // Only an actual status answer settles an unknown outcome; a failed or empty
            // reply leaves it unknown. The same answer is what ends the post-operation guard:
            // a query that established nothing leaves the environment unread, and the runtime
            // runs one development Mac at a time.
            if received, let status = statuses[id] {
                settle(status, for: id)
                // The runtime answered, so the connection that dropped during the operation is
                // back — but one environment's status is not the environment listing, the other
                // environments' states, or the runtime's own version, and all of those still
                // predate the dropped session. Ready is what a full reconciliation establishes
                // (MVP-PLAN.md §2), so the check is asked for here rather than declared: the
                // app stays interrupted until that check succeeds. One at a time, since a poll
                // inspecting a recovered operation reaches this every few seconds.
                if case .interrupted = launchState, reconciliationsInFlight == 0 { startRefresh() }
            }
            // The answer may name an operation nobody is streaming (the original event stream
            // was lost, or it was started before this launch). It is polled from here, so a
            // card never stays busy for an operation that has since finished.
            if statuses[id]?.inFlightOperation != nil, operations[id] == nil { startRecoveredOperationPoll() }
        } catch {
            guard statusGenerations[id] == generation else { return }
            // The query never answered. What was cached says nothing about the VM now, and
            // Quit must not choose stop targets from it: the status is dropped and the
            // environment is marked as unanswered, exactly as a failed reply would.
            statuses[id] = nil
            // A lost answer names no failure of its own: the interrupted launch state is what
            // reports it, and whatever the card already shows stays its own news.
            statusQueryFailures[id] = nil
            cancellationFailures[id] = nil
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
        operationFailures[id] = nil
        statusQueryFailures[id] = nil
        Task { await refreshStatus(of: id) }
    }

    /// Applies everything a fresh status settles for one environment. Every read of an actual
    /// status goes through this — the per-card inspection and the full reconciliation alike —
    /// so a card cannot be left showing a failure that the very snapshot it is published with
    /// has already disproved.
    ///
    /// The operation error that reported an outcome unknown is settled by the answer that
    /// resolved it: `EnvironmentCardState` derives its "Checking environment" presentation
    /// from that retained error, so leaving it would keep the card busy and Start disabled
    /// through every later successful check. A status that still reports an unresolved outcome
    /// is its own news and stays.
    private func settle(_ status: EnvironmentStatus, for id: EnvironmentID) {
        // An environment the runtime no longer lists is not settled by an answer about it. The
        // listing is what says the environment is there at all, and a marker on one that has
        // vanished names exactly the state nothing has established: clearing it here would let
        // a late answer — a poll's, or a check that crossed the listing — free a slot the
        // runtime never confirmed was free (MVP-PLAN.md §3).
        guard environments.contains(where: { $0.id == id }) else { return }
        if case .operationOutcomeUnknown? = lastErrors[id], Self.reportedUnknownOutcome(of: status) == nil {
            lastErrors[id] = nil
        }
        unknownOutcomes[id] = nil
        reconciling.remove(id)
        clearSettledCancellationFailure(of: id, against: status)
    }

    /// Drops a refused cancellation once an inspection shows its operation is no longer in
    /// flight. Only while it is still the failure the card shows: a later problem is its own
    /// news and is not cleared by this.
    private func clearSettledCancellationFailure(of id: EnvironmentID, against status: EnvironmentStatus) {
        guard let failure = cancellationFailures[id], status.inFlightOperation != failure.operation else { return }
        cancellationFailures[id] = nil
        if lastErrors[id] == failure.error { lastErrors[id] = nil }
    }

    // MARK: - Diagnostics

    /// Every redacted line the app holds, oldest first, each prefixed with the environment it
    /// belongs to (by UUID, never by address), so two development Macs' lines stay apart.
    /// The observations for one environment, so an export says which development Mac it is
    /// describing rather than picking one at random.
    func observations(of environment: EnvironmentID) -> ObservedTuple { statuses[environment]?.observed ?? ObservedTuple() }

    /// Everything the app still holds for one environment: what an earlier operation left
    /// behind, then what the operation in flight has said. A retry must not hide the failure
    /// output that explains why it is retrying, so these are joined rather than chosen between.
    func logs(of environment: EnvironmentID) -> [RedactedLine] {
        let retained = lastLogs[environment] ?? []
        let live = operations[environment]?.logs ?? []
        return Array((retained + live).suffix(OperationState.maximumLogLines))
    }

    var diagnosticsLines: [RedactedLine] { diagnosticsLines(of: environments) }

    /// The lines the diagnostics sheet shows: one environment's when it was opened from that
    /// environment's card, every environment's when it was opened from the toolbar or from a
    /// dashboard that has no cards.
    func diagnosticsLines(subject: EnvironmentID?) -> [RedactedLine] { diagnosticsLines(of: subjects(subject)) }

    /// The environments an export or the sheet describes. A subject that is no longer on the
    /// dashboard names nothing, so the bundle falls back to what it can still describe rather
    /// than to an empty report.
    private func subjects(_ subject: EnvironmentID?) -> [DevelopmentEnvironment] {
        guard let subject, let named = environments.first(where: { $0.id == subject }) else { return environments }
        return [named]
    }

    private func diagnosticsLines(of subjects: [DevelopmentEnvironment]) -> [RedactedLine] {
        subjects.flatMap { environment -> [RedactedLine] in
            // Scrubbed as a stream *before* the prefix goes on. A credential printed over two
            // lines is recognized by the line that ends in its label, and a UUID in front of
            // that label would hide it from the whole-line match.
            let scrubbed = DiagnosticsExportBuilder.scrubbedStream(logs(of: environment.id))
            // Prefixing goes back through the redactor: `RedactedLine` is only ever made there.
            return redactor.redact(lines: scrubbed.map { "\(environment.id.uuid.uuidString) \($0)" })
        }
    }

    /// The bundle "Export diagnostics" writes, describing the environment whose card opened
    /// the sheet.
    func diagnosticsExport(subject requested: EnvironmentID? = nil) -> DiagnosticsExport {
        let info = Bundle.main.infoDictionary ?? [:]
        // The manifest describes one environment: the one the user opened Diagnostics from,
        // and otherwise the first in creation order rather than whichever status happened to
        // be first in a dictionary. Exporting the first environment for a second one's card
        // would answer a report about the failing Mac with the healthy Mac's evidence.
        let subject = subjects(requested).first
        let compatibility = subject.map { observations(of: $0.id) } ?? ObservedTuple()
        return DiagnosticsExportBuilder.build(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            appBuild: info["CFBundleVersion"] as? String ?? "0",
            runtime: runtimeInfo,
            compatibility: compatibility,
            environments: subject.map { [$0] } ?? [],
            // Only the named environment's log. The manifest declares one environment ID and
            // one compatibility tuple, so lines prefixed with a second, undeclared UUID would
            // describe a development Mac the bundle says nothing else about.
            logs: diagnosticsLines(of: subject.map { [$0] } ?? []),
            // On a launch failure there is nothing else in the bundle: no environments, no
            // operation output. The error the user is looking at is the report.
            launchFailure: launchFailure,
            // An operation that failed before it wrote anything leaves no log either, so the
            // failure is carried in its own right. The operation's own failure comes first:
            // the mandatory check after it may fail as well, and that error takes the card
            // while the state stays unread, but it is not how the operation ended. A card with
            // no failed operation behind it still reports what it is showing.
            operationFailure: subject.flatMap { operationFailures[$0.id] ?? lastErrors[$0.id] }.map { .init($0) }
        )
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
                statusCheckFailed: statusQueryFailures[environment.id] != nil && statusQueriesInFlight[environment.id] == nil,
                unknownOutcome: unknownOutcomes[environment.id],
                statusQueryFailure: statusQueryFailures[environment.id],
                reconciling: reconciling.contains(environment.id),
                logs: logs(of: environment.id),
                retryAvailable: lastRequests[environment.id] != nil && !reconciling.contains(environment.id),
                retryBlockedReason: startRetryBlock(for: environment.id, block: block),
                startBlockedElsewhere: (operations[environment.id] == nil && statuses[environment.id]?.vm != .running) ? block : nil,
                runtimeVersion: runtimeInfo
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
        // The reconciliation this cancellation is sent under, so a disconnect reported after a
        // newer one has already re-established the app's state does not put the whole dashboard
        // back on the interrupted screen — and with no replacement check, since this path
        // starts none. The operation stream applies the same rule to its own loss.
        let generation = refreshGeneration
        Task {
            do {
                for try await event in backend.send(.cancelOperation(operation)) {
                    guard case .failed(_, let error) = event else { continue }
                    // A refusal is only news while that operation is still the one in flight.
                    // One that reached its own end meanwhile has already been reconciled, and
                    // its card must not show a cancellation failure for work that is over.
                    guard isInFlight(operation, for: id) else { return }
                    // Recorded like any other operation result, so it supersedes a status
                    // query that failed earlier while this operation ran. Left standing, that
                    // marker would let the next successful inspection clear this refusal as if
                    // it were the stale query failure, and the card would lose its error and
                    // its recovery controls while the operation is still in flight.
                    recordOperationError(error, for: id)
                    cancellationFailures[id] = CancellationFailure(operation: operation, error: error)
                }
            } catch {
                guard generation == refreshGeneration else { return }
                launchState = .interrupted(RuntimeConnectionInterrupted())
            }
        }
    }

    /// Whether that operation is still the one the environment is running, by either name.
    private func isInFlight(_ operation: OperationID, for id: EnvironmentID) -> Bool {
        operations[id]?.acceptedID == operation || statuses[id]?.inFlightOperation == operation
    }

    /// The recovery actions the GUI wires: retry re-sends the last request (never while the
    /// outcome is unknown), inspect re-reads the status, cancel dismisses the failure. The
    /// rest are shown as not implemented by the view.
    func perform(_ action: RecoveryAction, for id: EnvironmentID) {
        switch action {
        case .retry:
            // A retry answers the failure the card is showing. When that failure is the
            // inspection itself, another inspection is what it asks for: replaying a mutation
            // would act before the VM's actual state had been read back, and the failed query
            // is exactly what removed that state.
            if let shown = lastErrors[id], shown == statusQueryFailures[id] {
                Task { await refreshStatus(of: id) }
                return
            }
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
            // The check's own failure carries the card's only way to ask again while the
            // state is unread: dismissing it would leave the card on "Checking environment"
            // with nothing to press. The presentation disables the option for the same reason.
            guard let shown = lastErrors[id], shown != statusQueryFailures[id] else { return }
            lastErrors[id] = nil
            // A dismissed failure is not what the bundle reports either: the user said they
            // are done with it, and the next export describes what the card shows now.
            operationFailures[id] = nil
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
        operationFailures[id] = error
        statusQueryFailures[id] = nil
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
        // Whether the runtime described this environment while the operation ran. The courtesy
        // status refresh after a start or a stop is bounded and can time out, so an operation
        // that completed may still have said nothing about the VM.
        var described = false
        /// Set when a reconciliation that began after this stream has already read this
        /// environment's state back, so the loss has nothing left to establish.
        var answeredByReconciliation = false
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
                case .failed(_, let error):
                    recordOperationError(error, for: id)
                    // The runtime reports an unresolved mutation as a normal terminal failure
                    // when it cannot persist the result. That is the same unknown state as a
                    // stream this app lost, and is remembered as one until a status answers.
                    if case .operationOutcomeUnknown(let unresolved) = error { unknownOutcomes[id] = unresolved }
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
            // …and when that reconciliation has also finished, this environment's actual state
            // has been read back: that is the inspection an interrupted operation calls for,
            // so recreating an unknown marker over it, dropping the status it published and
            // asking again would undo it. The check that followed could then fail or hang and
            // leave Start and Quit blocked behind an outcome that had in fact been settled.
            if reconciledSinceStreamBegan(generation, of: id) {
                answeredByReconciliation = true
            } else {
                // The outcome is unknown until the runtime answers a status query; never
                // replay. Before acceptance the app's own label stands in: the runtime may or
                // may not have received the request.
                unknownOutcomes[id] = operations[id]?.acceptedID ?? operations[id]?.id
            }
        }
        // A start that failed or was lost may already have launched the VM, so what was cached
        // before it says nothing about the state now. The status is dropped before the
        // reservation is released: a cached `.stopped` would otherwise re-enable Start for the
        // seconds the inspection takes and let a second mutation go out over an outcome nobody
        // has established (AGENTS.md: never retry a mutating operation blindly).
        // Nor after one that completed without describing the environment: the courtesy status
        // refresh is bounded and can time out, leaving the pre-start reading behind.
        if !completed || !described, !answeredByReconciliation { statuses[id] = nil }
        lastLogs[id] = operations.removeValue(forKey: id)?.logs
        guard !answeredByReconciliation else {
            followRecoveredOperation(of: id)
            return
        }
        reconciling.insert(id)
        // A status that still names an operation (the connection dropped while the runtime
        // kept working) is polled until it settles; `refreshStatus` starts that itself, and
        // it is what ends the guard, so an inspection that failed leaves it standing.
        await refreshStatus(of: id)
        // The runtime may still be running the operation this app stopped listening to. A
        // reconciliation that ran while the operation was still local started a poll that found
        // nothing to follow and ended at once, so this handoff — from an operation this app
        // owned to one only the runtime reports — is where that poll has to be started again.
        // Without it the card stays busy and every start stays blocked until the user checks.
        followRecoveredOperation(of: id)
    }

    /// Whether a full reconciliation that began after `generation` has completed and published
    /// a status for this environment. That reading is newer than anything the interrupted
    /// stream knows, and it is what an unknown outcome is waiting for.
    private func reconciledSinceStreamBegan(_ generation: UInt64, of id: EnvironmentID) -> Bool {
        reconciledGeneration > generation && statuses[id] != nil
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

    /// The launch failure the user is looking at, if that is what they are looking at. A lost
    /// connection counts: the interrupted screen offers Diagnostics too, and on a fresh launch
    /// the bundle it produces has no environments and no logs to explain itself with.
    private var launchFailure: DiagnosticsExport.Manifest.ReportedFailure? {
        switch launchState {
        case .unavailable(let error):
            return .init(error)
        case .interrupted(let interruption):
            return .init(
                message: interruption.userMessage,
                recovery: interruption.recoveryMessage,
                recoveryActions: interruption.recoveryActions.map { String(describing: $0) }
            )
        case .checkingEnvironment, .ready:
            return nil
        }
    }

    private func launchStateError() -> GuesthouseError {
        if case .unavailable(let error) = launchState { return error }
        return .operationOutcomeUnknown(OperationID())
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
            // The runtime's own verdict counts here as it does in `globalStartBlock`: a
            // successful refresh clears this app's marker, so a status still reporting
            // `operationOutcomeUnknown` would otherwise let a stopped VM quit over a mutation
            // the runtime says it cannot account for.
            if let unknown = environmentsWithUnknownOutcome.first {
                quitFlow = .stopFailed(.operationOutcomeUnknown(unresolvedOperation(of: unknown) ?? OperationID()))
                return false
            }
            // A reconciliation marker still standing means an operation's state was never read
            // back: the check that would have settled it failed, and it is kept for exactly
            // that reason. An environment the listing has since dropped is not inspected by the
            // loop above at all, so an ordinary failure there — no unknown-outcome marker of
            // its own — would let the quit terminate over a VM that may still be running (§2).
            if let unread = reconciling.first {
                quitFlow = .stopFailed(lastErrors[unread] ?? .operationOutcomeUnknown(unresolvedOperation(of: unread) ?? OperationID()))
                return false
            }
            let busy = operations.keys.first ?? statuses.values.first(where: { $0.inFlightOperation != nil })?.environmentID
            guard let busy else { return true }
            quitFlow = .waitingForOperations(busy)
            // The runtime runs a Tart command for every status query, so this waits in
            // seconds rather than polling several times a second.
            try? await Task.sleep(for: quitWaitPollInterval)
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
                    case .log(_, let line):
                        // Shutdown output belongs in diagnostics: it is what explains a stop
                        // that failed, and the quit sheet does not show it.
                        var logs = lastLogs[environment.id] ?? []
                        logs.append(line)
                        if logs.count > OperationState.maximumLogLines { logs.removeFirst(logs.count - OperationState.maximumLogLines) }
                        lastLogs[environment.id] = logs
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
