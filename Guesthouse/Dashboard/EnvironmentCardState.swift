import Foundation
import GuesthouseCore

/// What one dashboard card shows and which actions it offers, derived from what the runtime
/// reported. Unavailable actions are disabled with a reason, never hidden (MVP-PLAN.md §2).
struct EnvironmentCardState: Equatable, Identifiable {
    enum Action: String, CaseIterable, Identifiable {
        case start, stop, openInCodex, openConsole, testWorkspace, publishDrafts
        case repair, exportWork, delete

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
            }
        }

        /// Primary actions are buttons on the card; the rest live in the overflow menu, with
        /// Delete separated and destructive so it never looks like a routine fix.
        var isPrimary: Bool {
            switch self {
            case .start, .stop, .openInCodex, .openConsole, .testWorkspace, .publishDrafts: true
            case .repair, .exportWork, .delete: false
            }
        }

        var isDestructive: Bool { self == .delete }
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
        logs: [RedactedLine] = [],
        startBlockedElsewhere: String? = nil,
        runtimeVersion: RuntimeVersionInfo? = nil
    ) {
        id = environment.id
        name = environment.name
        let statusAttention: GuesthouseError? = {
            if case .needsAttention(let error)? = status?.readiness { return error }
            return nil
        }()
        let attention: GuesthouseError? = statusAttention ?? lastError
        self.attention = attention
        recoveryActions = attention?.recoveryActions ?? []
        canDismiss = statusAttention == nil && lastError != nil
        phase = operation?.phase
        progress = operation.map { OperationProgressPresentation(phase: $0.phase, request: $0.request) }
        outcomeUnknown = unknownOutcome != nil
        recovery = if let unknownOutcome {
            RecoveryPresentation(unknownOutcomeOf: unknownOutcome)
        } else if let attention {
            RecoveryPresentation(error: attention)
        } else {
            nil
        }
        self.logs = logs
        // A status the last query could not read is not a check in progress: that query ended,
        // and the card names the failure it is already showing rather than turning an error
        // with its own recovery into an indefinite spinner nobody can end.
        let unread = statusUnread || status == nil
        isBusy = (unread && !statusCheckFailed) || status?.readiness == .checking || status?.inFlightOperation != nil || operation != nil || unknownOutcome != nil
        statusText = unknownOutcome != nil ? "Checking environment…" : Self.statusText(for: status, operation: operation, checkFailed: statusCheckFailed)
        details = Self.details(for: environment, status: status, runtimeVersion: runtimeVersion)
        // A status nobody has read back yet is not a state to act on: Start stays disabled
        // until the environment answers again.
        availability = Self.availability(for: statusUnread ? nil : status, operation: operation, attention: attention, outcomeUnknown: unknownOutcome != nil, blockedElsewhere: startBlockedElsewhere)
    }

    func availability(of action: Action) -> Availability {
        availability[action] ?? .disabled(reason: "Not available")
    }

    private static func statusText(for status: EnvironmentStatus?, operation: AppModel.OperationState?, checkFailed: Bool) -> String {
        if let operation {
            return operation.phase.map { describe($0) } ?? "Starting…"
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

    private static func availability(for status: EnvironmentStatus?, operation: AppModel.OperationState?, attention: GuesthouseError?, outcomeUnknown: Bool, blockedElsewhere: String?) -> [Action: Availability] {
        var table: [Action: Availability] = [:]
        for action in Action.allCases where action != .start {
            table[action] = .notImplemented(note: Self.notImplementedNote(for: action))
        }
        table[.start] = startAvailability(for: status, operation: operation, attention: attention, outcomeUnknown: outcomeUnknown, blockedElsewhere: blockedElsewhere)
        return table
    }

    private static func startAvailability(for status: EnvironmentStatus?, operation: AppModel.OperationState?, attention: GuesthouseError?, outcomeUnknown: Bool, blockedElsewhere: String?) -> Availability {
        guard !outcomeUnknown, let status, status.readiness != .checking else { return .disabled(reason: "Checking environment") }
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
        case .start: ""
        case .stop: "Stopping from the dashboard arrives with the real runtime wiring (#32)."
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
