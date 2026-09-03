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
    /// The problem the runtime reported, if any, with its recovery actions.
    let attention: GuesthouseError?
    let details: [Detail]
    let availability: [Action: Availability]

    init(environment: DevelopmentEnvironment, status: EnvironmentStatus?, operation: AppModel.OperationState?, lastError: GuesthouseError?) {
        id = environment.id
        name = environment.name
        let attention: GuesthouseError? = {
            if case .needsAttention(let error)? = status?.readiness { return error }
            return lastError
        }()
        self.attention = attention
        phase = operation?.phase
        isBusy = status == nil || status?.readiness == .checking || status?.inFlightOperation != nil || operation != nil
        statusText = Self.statusText(for: status, operation: operation)
        details = Self.details(for: environment, status: status)
        availability = Self.availability(for: status, operation: operation, attention: attention)
    }

    func availability(of action: Action) -> Availability {
        availability[action] ?? .disabled(reason: "Not available")
    }

    private static func statusText(for status: EnvironmentStatus?, operation: AppModel.OperationState?) -> String {
        if let operation {
            return operation.phase.map { describe($0) } ?? "Starting…"
        }
        guard let status else { return "Checking environment…" }
        if status.inFlightOperation != nil { return "Operation in progress…" }
        switch status.readiness {
        case .checking: return "Checking environment…"
        case .needsAttention: return "Needs attention"
        case .ready:
            switch status.vm {
            case .running: return "Running"
            case .stopped: return "Stopped"
            case .notFound: return "Virtual machine missing"
            case .uncertain: return "Ownership uncertain"
            }
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

    private static func details(for environment: DevelopmentEnvironment, status: EnvironmentStatus?) -> [Detail] {
        let observed = status?.observed
        return [
            Detail(label: "Disk", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: environment.guestDiskBytes), countStyle: .file)),
            Detail(label: "Xcode", value: observed?.xcodeBuild ?? "Unknown"),
            Detail(label: "Guest macOS", value: observed?.guestMacOSBuild ?? "Unknown"),
            Detail(label: "Runtime", value: observed?.tartVersion.map { "Tart \($0)" } ?? "Unknown"),
            Detail(label: "Codex CLI", value: observed?.codexCLIVersion ?? "Unknown"),
            Detail(label: "Accounts", value: "Unknown"),
        ]
    }

    private static func availability(for status: EnvironmentStatus?, operation: AppModel.OperationState?, attention: GuesthouseError?) -> [Action: Availability] {
        var table: [Action: Availability] = [:]
        for action in Action.allCases where action != .start {
            table[action] = .notImplemented(note: Self.notImplementedNote(for: action))
        }
        table[.start] = startAvailability(for: status, operation: operation, attention: attention)
        return table
    }

    private static func startAvailability(for status: EnvironmentStatus?, operation: AppModel.OperationState?, attention: GuesthouseError?) -> Availability {
        guard let status, status.readiness != .checking else { return .disabled(reason: "Checking environment") }
        if operation != nil || status.inFlightOperation != nil { return .disabled(reason: "An operation is in progress") }
        if let attention { return .disabled(reason: attention.userMessage) }
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
