import Foundation

/// Error explanations owned by Guesthouse, not copied from subprocesses or Error descriptions.
/// Unknown errors stay actionable without attempting to recognize secrets in their text.
public enum DiagnosticFailure: String, CaseIterable, Codable, Error, Sendable {
    case timedOut, connectionFailed, authenticationRequired, credentialsLocked
    case executableUnavailable, permissionDenied, insufficientDiskSpace
    case verificationFailed, invalidResponse, processFailed, outcomeUnknown

    public var message: String {
        switch self {
        case .timedOut: "The operation timed out; its outcome may be unknown."
        case .connectionFailed: "Guesthouse could not connect to the development Mac."
        case .authenticationRequired: "Sign-in is required to continue."
        case .credentialsLocked: "The credentials needed for this operation are locked."
        case .executableUnavailable: "A required tool is missing or could not be launched."
        case .permissionDenied: "Guesthouse does not have the required access."
        case .insufficientDiskSpace: "There is not enough disk space for this operation."
        case .verificationFailed: "The runtime or connection failed its trust check."
        case .invalidResponse: "A tool returned an unsupported or incomplete response."
        case .processFailed: "The tool reported a failure."
        case .outcomeUnknown: "The operation's outcome could not be confirmed."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .timedOut, .processFailed, .outcomeUnknown:
            "Inspect the development Mac's current state before trying the operation again."
        case .connectionFailed:
            "Check that the development Mac is running and its SSH connection is available."
        case .authenticationRequired:
            "Open Accounts and sign in again."
        case .credentialsLocked:
            "Unlock the guest Keychain, then check account readiness."
        case .executableUnavailable:
            "Open Repair and check the required tool installation."
        case .permissionDenied:
            "Review the access requested by this operation in Settings."
        case .insufficientDiskSpace:
            "Free disk space, then check the environment before retrying."
        case .verificationFailed:
            "Use Repair to inspect the runtime or SSH identity; do not bypass verification."
        case .invalidResponse:
            "Check tool compatibility in Repair and inspect the environment before retrying."
        }
    }
}

extension DiagnosticFailure: LocalizedError {
    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recoveryMessage }
}
