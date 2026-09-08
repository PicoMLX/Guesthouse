/// User-initiated recovery choices, never an instruction to automatically retry a mutation.
public enum RecoveryAction: Codable, Hashable, Sendable {
    case retry, inspectState, repair(RepairKind), openConsole, exportWork, openSettings
    case signInAgain, freeDiskSpace, deleteEnvironment, reinstallApp, cancel

    public var title: String {
        switch self {
        case .retry: "Try again"
        case .inspectState: "Inspect the current environment state"
        case .repair(let kind): kind.title
        case .openConsole: "Open the development Mac console"
        case .exportWork: "Export unpublished work"
        case .openSettings: "Open Settings"
        case .signInAgain: "Sign in again"
        case .freeDiskSpace: "Free disk space"
        case .deleteEnvironment: "Delete an unused environment after exporting its work"
        case .reinstallApp: "Reinstall Guesthouse"
        case .cancel: "Cancel"
        }
    }
}

public enum RepairKind: String, Codable, Hashable, Sendable, CaseIterable {
    case sshPairing, credentials, runtime, tools, xcodeComponents, download

    public var title: String {
        switch self {
        case .sshPairing: "Repair SSH pairing without bypassing trust checks"
        case .credentials: "Check credential access"
        case .runtime: "Repair the verified runtime installation"
        case .tools: "Check tool compatibility"
        case .xcodeComponents: "Install the required Xcode components"
        case .download: "Download a verified replacement from the trusted source without bypassing verification"
        }
    }
}
