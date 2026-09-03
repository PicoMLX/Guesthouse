/// What a failed Tart invocation most likely means, from its stderr text.
///
/// Phrases come from `RuntimeError`'s descriptions in Tart 2.36.0 (`VMStorageHelper.swift`,
/// `Commands/Run.swift`, `Commands/IP.swift`, `PIDLock.swift`). Matching is by substring,
/// case-insensitively, so a prefix such as `Error:` does not matter. Unknown text is kept
/// only in redacted form.
public enum TartFailure: Hashable, Sendable {
    /// `the specified VM "name" does not exist`
    case vmNotFound
    /// `VM "name" is already running!`
    case alreadyRunning
    /// `VM "name" is not running`
    case notRunning
    /// `VM "name" is running` (an operation that needs a stopped VM)
    case requiresStoppedVM
    /// `no IP address found, is your VM running?`
    case noIPAddress
    /// `failed to lock <path>` (another Tart process holds the VM). A failure to open the lock
    /// file is not contention and stays unknown.
    case lockHeld
    /// `VM directory is already initialized, preventing overwrite`
    case directoryAlreadyInitialized
    /// The disk image is in use elsewhere, for example mounted in Finder.
    case diskInUse
    /// `The number of VMs exceeds the system limit`.
    case virtualMachineLimitExceeded
    case unknown(RedactedLine)
}

public enum TartErrorClassifier {
    public static func classify(stderr: String, exitStatus: Int32) -> TartFailure {
        let text = stderr.lowercased()
        func has(_ phrase: String) -> Bool { text.contains(phrase) }

        if has("the specified vm") && has("does not exist") { return .vmNotFound }
        if has("is already running") { return .alreadyRunning }
        if has("is not running") { return .notRunning }
        if has("no ip address found") { return .noIPAddress }
        if has("failed to lock ") { return .lockHeld }
        if has("vm directory is already initialized") { return .directoryAlreadyInitialized }
        if has("disk") && has("in use") { return .diskInUse }
        if has("the number of vms exceeds the system limit") { return .virtualMachineLimitExceeded }
        if has("is running") || has("must be stopped") { return .requiresStoppedVM }
        let firstLine = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(exitStatus)"
        return .unknown(Redactor().redact(lines: [firstLine]).first ?? RedactedLine(literal: "unknown Tart failure"))
    }
}
