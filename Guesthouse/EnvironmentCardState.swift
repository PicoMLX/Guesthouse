import Foundation
import GuesthouseCore

/// Presentation only, never runtime admission (MVP-PLAN.md §§1–2, 5; retained #77).
struct EnvironmentCardState: Equatable, Identifiable {
    enum Action: String, CaseIterable, Identifiable {
        case start, stop, openInCodex, openConsole, testWorkspace, publishDrafts, repair, exportWork, startFresh, delete
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
            case .startFresh: "Start fresh…"
            case .delete: "Delete environment…"
            }
        }
        var primary: Bool { switch self { case .repair, .exportWork, .startFresh, .delete: false; default: true } }
        var unavailableReason: String {
            switch self {
            case .start: "A fresh, idle stopped state is required before starting."
            case .stop: "Stopping from the dashboard is not available yet. Normal Quit offers Stop environments and quit."
            case .openInCodex: "Codex connection has not been configured and verified."
            case .openConsole: "The development Mac console is not available yet."
            case .testWorkspace: "Workspace testing is not available yet."
            case .publishDrafts: "Publishing draft pull requests is not available yet."
            case .repair: "Guided repair is not available yet. Inspect the environment before continuing."
            case .exportWork: "Work export is not available yet. Saved disks are retained."
            case .startFresh: "Starting fresh is unavailable until existing work can be reviewed, exported or preserved."
            case .delete: "Deletion is unavailable until work can be reviewed and exported."
            }
        }
    }
    struct Detail: Equatable, Identifiable {
        let label: String, value: String
        var id: String { label }
    }
    let id: EnvironmentID
    let name: String
    let statusText: String
    let guidance: String?
    let details: [Detail]
    let startBlockedReason: String

    init(environment: DevelopmentEnvironment, status candidate: EnvironmentStatus?, checked: Bool, busy: Bool) {
        id = environment.id; name = environment.name
        let status = checked && candidate?.environmentID == environment.id ? candidate : nil
        switch status?.vm {
        case .running: statusText = "Running"
        case .stopped: statusText = "Stopped"
        case .notFound: statusText = "Development Mac not found"
        case .uncertain: statusText = "State needs inspection"
        case nil: statusText = "Current state unknown"
        }
        if let status, case .uncertain(let reason) = status.vm {
            guidance = reason.userMessage + " Inspect the environment before continuing."
        } else if let status, case .needsAttention(let error) = status.readiness {
            guidance = error.userMessage + " " + error.recoveryMessage
        } else if status?.inFlightOperation != nil {
            guidance = "An operation is in progress. Wait for its outcome before starting new work."
        } else if status?.vm == .stopped {
            guidance = "Start retains saved work on the same VM disk."
        } else if status?.vm == .notFound {
            guidance = "Inspect saved metadata and storage. Missing state does not authorize deletion."
        } else { guidance = nil }
        if busy { startBlockedReason = "Wait for the current check or Quit attempt." }
        else if status == nil { startBlockedReason = "Check the environment before starting." }
        else if status?.inFlightOperation != nil { startBlockedReason = "An operation is in progress." }
        else if status?.vm == .running { startBlockedReason = "Already running." }
        else if status?.vm != .stopped { startBlockedReason = "Inspect the environment before starting." }
        else if case .needsAttention(let error)? = status?.readiness { startBlockedReason = error.recoveryMessage }
        else { startBlockedReason = Action.start.unavailableReason }
        let observed = status?.observed
        details = [
            Detail(label: "Disk capacity", value: environment.guestDiskBytes.formatted() + " bytes"),
            Detail(label: "Disk usage", value: "Not measured"),
            Detail(label: "Xcode build", value: observed?.xcodeBuild ?? "Unknown"),
            Detail(label: "Guest macOS build", value: observed?.guestMacOSBuild ?? "Unknown"),
            Detail(label: "VM runtime", value: observed?.runtimeVersion ?? "Unknown"),
            Detail(label: "Codex CLI", value: observed?.codexCLIVersion ?? "Unknown"),
            Detail(label: "Accounts", value: "Not checked")
        ]
    }
    func reason(for action: Action) -> String { action == .start ? startBlockedReason : action.unavailableReason }
}

extension EnvironmentCapability {
    var dashboardTitle: String {
        switch self {
        case .connection: "Codex connection"
        case .buildTools: "Build tools"
        case .credentials: "Credentials"
        case .desktop: "Guest desktop"
        case .guiAutomation: "GUI automation"
        }
    }
}
