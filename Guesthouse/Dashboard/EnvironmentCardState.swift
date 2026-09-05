import Foundation
import GuesthouseCore

/// What one dashboard card shows and which actions it offers, derived from what the runtime
/// reported. Unavailable actions are disabled with a reason, never hidden (MVP-PLAN.md §2).
struct EnvironmentCardState: Equatable, Identifiable {
    enum Action: String, CaseIterable, Identifiable {
        case start, stop, openInCodex, openConsole, testWorkspace, publishDrafts
        case repair, exportWork, delete
        /// Offered only after a graceful stop timed out; confirmed with a warning first.
        case forceStop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .start: "Start"
            case .stop: "Stop"
            case .openInCodex: "Open in Codex"
            case .openConsole: "Open Mac console"
            case .testWorkspace: "Test workspace"
            case .publishDrafts: "Publish draft PRs"
            case .repair: "Repair…"
            case .exportWork: "Export work…"
            case .delete: "Delete environment…"
            case .forceStop: "Force stop…"
            }
        }

        /// Primary actions are buttons on the card; the rest live in the overflow menu, with
        /// Delete separated and destructive so it never looks like a routine fix.
        var isPrimary: Bool {
            switch self {
            case .start, .stop, .openInCodex, .openConsole, .testWorkspace, .publishDrafts, .forceStop: true
            case .repair, .exportWork, .delete: false
            }
        }

        var isDestructive: Bool { self == .delete || self == .forceStop }
    }

    enum Availability: Equatable {
        case enabled
        /// Present but disabled; the reason is shown as help text and read by VoiceOver.
        case disabled(reason: String)
        /// Present, and tapping it says so instead of doing nothing.
        case notImplemented(note: String)
    }

    struct Detail: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let id: EnvironmentID
    let name: String
    let statusText: String
    /// True while the runtime is reconciling or an operation is in flight.
    let isBusy: Bool
    let phase: ProgressPhase?
    /// The running operation, for the progress view.
    let progress: OperationProgressPresentation?
    /// The problem the runtime reported, if any, with its recovery actions.
    let attention: GuesthouseError?
    /// What the user can do about `attention`, in the error's own order. The card renders
    /// these, so an error whose recovery is an inspection or a repair is never shown as text
    /// with no way out (AGENTS.md: every error carries at least one recovery action).
    let recoveryActions: [RecoveryAction]

    /// What to show for the problem, or for an operation whose outcome is unknown.
    let recovery: RecoveryPresentation?
    /// True after a lost connection until a status query succeeds.
    let outcomeUnknown: Bool
    let logs: [RedactedLine]
    let details: [Detail]
    let availability: [Action: Availability]

    init(
        environment: DevelopmentEnvironment,
        status: EnvironmentStatus?,
        operation: AppModel.OperationState?,
        lastError: GuesthouseError?,
        statusUnread: Bool = false,
        /// This environment's last status query ended in a failure and no other query is
        /// running. The status is unread, but nothing is being checked.
        statusCheckFailed: Bool = false,
        unknownOutcome: OperationID? = nil,
        /// The failure of this environment's last status query, when that is what failed.
        statusQueryFailure: GuesthouseError? = nil,
        reconciling: Bool = false,
        logs: [RedactedLine] = [],
        retryAvailable: Bool = true,
        retryBlockedReason: String? = nil,
        startBlockedElsewhere: String? = nil,
        runtimeVersion: RuntimeVersionInfo? = nil,
        operationElsewhere: String? = nil,
        forceStopAvailable: Bool = false,
        lastRequest: RuntimeRequest? = nil
    ) {
        id = environment.id
        name = environment.name
        let statusAttention: GuesthouseError? = {
            if case .needsAttention(let error)? = status?.readiness { return error }
            return nil
        }()
        // While an operation runs, a failure this window just caused — a cancellation the
        // runtime refused — is the news the user is waiting for; the status's standing
        // attention is not new and would otherwise hide it (MVP-PLAN.md §2). An operation only
        // the status reports counts the same way: a recovered operation has no local record,
        // so a refused cancellation of one used to sit behind the standing attention and the
        // user could believe the stop they asked for had been accepted.
        let running = operation != nil || status?.inFlightOperation != nil
        let attention: GuesthouseError? = (running ? lastError : nil) ?? statusAttention ?? lastError
        self.attention = attention
        recoveryActions = attention?.recoveryActions ?? []
        phase = operation?.phase
        // An operation the status reports without a local counterpart (recovered after a
        // relaunch or a dropped connection) gets the same progress and Cancel controls.
        progress = if let operation {
            OperationProgressPresentation(phase: operation.phase, request: operation.request, accepted: operation.acceptedID != nil)
        } else if let recovered = status?.inFlightOperation {
            OperationProgressPresentation(recoveredOperation: recovered, request: lastRequest)
        } else {
            nil
        }
        // The runtime reports an unresolved operation as an error on the status too; that is
        // the same unknown state as a locally lost stream and is presented as one, rather than
        // as a settled "Needs attention" beside a panel that says it is still checking.
        let reportedUnknown: Bool = if case .operationOutcomeUnknown = attention { true } else { false }
        let unknown = unknownOutcome != nil || reportedUnknown
        outcomeUnknown = unknown
        recovery = if let unknownOutcome {
            // The outcome stays unknown, and the failure of the check that would settle it is
            // shown with it: another bare Check button would hide why the last one failed.
            RecoveryPresentation(unknownOutcomeOf: unknownOutcome, inspectionFailure: statusQueryFailure)
        } else if let attention {
            RecoveryPresentation(
                error: attention,
                retryAvailable: retryAvailable,
                retryBlockedReason: retryBlockedReason,
                dismissBlockedReason: Self.dismissBlock(attention: attention, statusAttention: statusAttention, statusQueryFailure: statusQueryFailure),
                // The check's own failure is answered by another check. Its error may carry no
                // action that does anything here — `.invalidRequest` and `.unauthorizedCaller`
                // offer only Dismiss, which is disabled while the state is unread — and the
                // card would then be a message with no control the user can press, its status
                // nil and Start refused (AGENTS.md: every error carries a recovery that works).
                inspectionOffered: attention == statusQueryFailure
            )
        } else {
            nil
        }
        self.logs = logs
        // A status still being read back after an operation is not a state to act on either:
        // the model refuses everything until the answer lands, and the card says so. A status
        // the last query could not read is different: that query ended, so the card names the
        // failure it is already showing rather than spinning on a check nobody can end.
        let checking = unknown || reconciling
        let unread = statusUnread || status == nil
        isBusy = (unread && !statusCheckFailed) || status?.readiness == .checking || status?.inFlightOperation != nil || operation != nil || checking
        statusText = checking ? "Checking environment…" : Self.statusText(for: status, operation: operation, checkFailed: statusCheckFailed)
        details = Self.details(for: environment, status: status, runtimeVersion: runtimeVersion)
        // A status nobody has read back yet is not a state to act on: Start stays disabled
        // until the environment answers again.
        availability = Self.availability(for: statusUnread ? nil : status, operation: operation, attention: attention, checking: checking, blockedElsewhere: startBlockedElsewhere, operationElsewhere: operationElsewhere, forceStopAvailable: forceStopAvailable)
    }

    func availability(of action: Action) -> Availability {
        availability[action] ?? .disabled(reason: "Not available")
    }

    /// Why the failure cannot be dismissed, when it cannot. A problem the status keeps
    /// reporting would leave the identical panel in place; the check's own failure carries the
    /// card's only way to ask again, and dismissing it would leave the card on "Checking
    /// environment" with no action at all while the state is still unread.
    private static func dismissBlock(attention: GuesthouseError, statusAttention: GuesthouseError?, statusQueryFailure: GuesthouseError?) -> String? {
        if attention == statusAttention {
            return "The runtime still reports this, so dismissing it would change nothing. It clears when the development Mac reports otherwise."
        }
        if attention == statusQueryFailure {
            return "This is the check itself failing, and the development Mac's state is still unread. Check the environment again; the message clears once a check succeeds."
        }
        return nil
    }

    private static func statusText(for status: EnvironmentStatus?, operation: AppModel.OperationState?, checkFailed: Bool = false) -> String {
        if let operation {
            // Before the first phase arrives the request says what is happening: a slow stop
            // must never be announced as a start.
            return operation.phase.map { describe($0) } ?? OperationProgressPresentation(phase: nil, request: operation.request).title
        }
        guard let status else { return checkFailed ? "Last check failed" : "Checking environment…" }
        if status.inFlightOperation != nil { return "Operation in progress…" }
        let vm = describe(status.vm)
        switch status.readiness {
        case .checking: return "Checking environment…"
        // Both states are reported: a running VM that is not reachable is still running, and
        // the card must not hide that (MVP-PLAN.md §2).
        case .needsAttention: return "\(vm), needs attention"
        case .ready: return vm
        }
    }

    static func describe(_ vm: EnvironmentStatus.VMState) -> String {
        switch vm {
        case .running: "Running"
        case .stopped: "Stopped"
        case .notFound: "Virtual machine missing"
        case .uncertain: "Ownership uncertain"
        }
    }

    static func describe(_ phase: ProgressPhase) -> String {
        switch phase.kind {
        case .inspectingState: "Checking the current state…"
        case .verifyingRuntime: "Verifying the virtual machine runtime…"
        case .startingVM: "Starting the virtual machine…"
        case .waitingForNetwork: "Waiting for the development Mac to answer…"
        case .stoppingVM: "Shutting down…"
        case .forceStoppingVM: "Force-stopping…"
        case .validatingSelection: "Validating the selection…"
        case .copying: "Copying…"
        case .verifyingCopy: "Verifying the copy…"
        }
    }

    private static func details(for environment: DevelopmentEnvironment, status: EnvironmentStatus?, runtimeVersion: RuntimeVersionInfo?) -> [Detail] {
        let observed = status?.observed
        // A status carries no Tart version: the service reports the bundle it verified once,
        // for the whole host, so that is what the row shows when the environment has no
        // observation of its own.
        let tart = observed?.tartVersion ?? runtimeVersion?.tart?.version
        // The guest's logical capacity is not its consumption (MVP-PLAN.md §4), and nothing
        // observes the latter yet: the two are separate rows so a sparse 160 GB disk is never
        // read as 160 GB of work. Account status is not observed yet either, and both rows say
        // so instead of letting capacity stand in for a value nobody measured.
        return [
            Detail(label: "Disk capacity", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: environment.guestDiskBytes), countStyle: .file)),
            Detail(label: "Disk usage", value: "Not observed yet"),
            Detail(label: "Xcode", value: observed?.xcodeBuild ?? "Unknown"),
            Detail(label: "Guest macOS", value: observed?.guestMacOSBuild ?? "Unknown"),
            Detail(label: "Runtime", value: tart.map { "Tart \($0)" } ?? "Unknown"),
            Detail(label: "Codex CLI", value: observed?.codexCLIVersion ?? "Unknown"),
            Detail(label: "Accounts", value: "Not observed yet"),
        ]
    }

    private static func availability(for status: EnvironmentStatus?, operation: AppModel.OperationState?, attention: GuesthouseError?, checking: Bool, blockedElsewhere: String?, operationElsewhere: String?, forceStopAvailable: Bool) -> [Action: Availability] {
        var table: [Action: Availability] = [:]
        for action in Action.allCases where action != .start && action != .stop && action != .forceStop {
            table[action] = .notImplemented(note: Self.notImplementedNote(for: action))
        }
        table[.start] = startAvailability(for: status, operation: operation, attention: attention, checking: checking, blockedElsewhere: blockedElsewhere)
        table[.stop] = stopAvailability(for: status, operation: operation, checking: checking, blockedElsewhere: blockedElsewhere, operationElsewhere: operationElsewhere)
        table[.forceStop] = forceStopAvailable ? .enabled : .disabled(reason: "Force-stopping is offered only after a normal stop did not finish in time.")
        return table
    }

    /// Stop is disabled with a reason rather than hidden, like every other action here, and is
    /// enabled for a running VM. The stop and warned force-stop contract is MVP-PLAN.md §2
    /// ("Returning developer").
    private static func stopAvailability(for status: EnvironmentStatus?, operation: AppModel.OperationState?, checking: Bool, blockedElsewhere: String?, operationElsewhere: String?) -> Availability {
        guard !checking, let status, status.readiness != .checking else { return .disabled(reason: "Checking environment") }
        // An outcome the runtime reports as unresolved is inspected before anything is sent
        // again, exactly as one this app observed being interrupted (MVP-PLAN.md §3).
        if case .needsAttention(.operationOutcomeUnknown) = status.readiness { return .disabled(reason: "Checking environment") }
        if operation != nil || status.inFlightOperation != nil { return .disabled(reason: "An operation is in progress") }
        // The runtime takes one lifecycle operation at a time and would refuse this one.
        if let operationElsewhere { return .disabled(reason: operationElsewhere) }
        if let blockedElsewhere, status.vm != .running { return .disabled(reason: blockedElsewhere) }
        switch status.vm {
        case .running: return .enabled
        case .stopped: return .disabled(reason: "Not running")
        case .notFound: return .disabled(reason: "The virtual machine is missing")
        case .uncertain(let reason): return .disabled(reason: "Ownership is uncertain (\(reason)). Repair before stopping.")
        }
    }

    /// - Parameter checking: the outcome of the last operation is unknown, or its status is
    ///   still being read back. Either way the model refuses a start, so the card must not
    ///   offer one that silently does nothing.
    private static func startAvailability(for status: EnvironmentStatus?, operation: AppModel.OperationState?, attention: GuesthouseError?, checking: Bool, blockedElsewhere: String?) -> Availability {
        guard !checking, let status, status.readiness != .checking else { return .disabled(reason: "Checking environment") }
        if operation != nil || status.inFlightOperation != nil { return .disabled(reason: "An operation is in progress") }
        // A failure the runtime says is not retryable is not answered by pressing Start again.
        if let attention, !attention.isRetryable { return .disabled(reason: attention.userMessage) }
        if let blockedElsewhere { return .disabled(reason: blockedElsewhere) }
        // A preserved slot is never startable, whatever the VM's state: the runtime refuses it
        // until the slot is repaired.
        if case .environmentPreserved? = attention { return .disabled(reason: attention?.userMessage ?? "This development Mac is preserved") }
        // A failed start does not lock Start forever: once the status re-check reports a
        // stopped, ready VM, Start is a retry and the runtime's own recovery actions apply.
        if let attention, status.readiness != .ready || status.vm != .stopped { return .disabled(reason: attention.userMessage) }
        switch status.vm {
        case .stopped: return .enabled
        case .running: return .disabled(reason: "Already running")
        case .notFound: return .disabled(reason: "The virtual machine is missing")
        case .uncertain(let reason): return .disabled(reason: "Ownership is uncertain (\(reason)). Repair before starting.")
        }
    }

    private static func notImplementedNote(for action: Action) -> String {
        switch action {
        case .start, .stop, .forceStop: ""
        case .openInCodex: "Handing off to Codex desktop arrives in Phase 2 (MVP-PLAN.md §10)."
        case .openConsole: "The Mac console arrives in Phase 2 (MVP-PLAN.md §10)."
        case .testWorkspace: "Workspace tests arrive in Phase 2 (MVP-PLAN.md §10)."
        case .publishDrafts: "Publishing draft PRs arrives in Phase 3 (MVP-PLAN.md §10)."
        case .repair: "Targeted repairs arrive with the repair flows (MVP-PLAN.md §9)."
        case .exportWork: "Work export arrives in Phase 3 (MVP-PLAN.md §10)."
        case .delete: "Deletion arrives after work export exists, so it can never be the only way out (MVP-PLAN.md §2)."
        }
    }
}
