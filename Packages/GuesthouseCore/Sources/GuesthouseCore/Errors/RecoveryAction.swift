/// What the user can do about an error. Every `GuesthouseError` offers at least one.
///
/// The GUI renders these as buttons (MVP-PLAN.md §10, Phase 1: "Never show 'something went
/// wrong' as the only recovery information").
public enum RecoveryAction: Codable, Hashable, Sendable {
    /// Run the same operation again. Only offered when the outcome of the last attempt is known.
    case retry
    /// Re-read the actual VM, guest, and journal state before deciding anything.
    case inspectState
    /// Start a targeted repair flow (MVP-PLAN.md §9).
    case repair(RepairKind)
    /// Open the guest console for a step that needs the user at the guest's screen.
    case openConsole
    /// Export unpublished work before a disruptive action.
    case exportWork
    /// Open the relevant settings screen (host power, storage location, accounts).
    case openSettings
    /// Run the provider sign-in flow again.
    case signInAgain
    /// Free disk space, then continue.
    case freeDiskSpace
    /// Abandon the operation.
    case cancel
}

/// The targeted repairs MVP-PLAN.md §9 promises instead of "delete the VM and start again".
public enum RepairKind: String, Codable, Hashable, Sendable, CaseIterable {
    case sshPairing
    case credentials
    case runtime
    case tools
    case xcodeComponents
}
