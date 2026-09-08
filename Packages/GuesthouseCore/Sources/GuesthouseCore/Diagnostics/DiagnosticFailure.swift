import Foundation

/// Error explanations owned by Guesthouse, not copied from subprocesses or Error descriptions.
/// Unknown errors stay actionable without attempting to recognize secrets in their text.
public enum DiagnosticFailure: String, CaseIterable, Codable, Error, Sendable {
    case unsupportedHost
    case timedOut, connectionFailed, authenticationRequired, credentialsLocked
    case guestAuthenticationFailed
    case executableUnavailable, permissionDenied, insufficientDiskSpace
    case verificationFailed, invalidResponse, processFailed, outcomeUnknown

    public var message: String {
        switch self {
        case .unsupportedHost: "This Mac does not meet Guesthouse's supported host requirements."
        case .timedOut: "The operation timed out; its outcome may be unknown."
        case .connectionFailed: "Guesthouse could not connect to the development Mac."
        case .authenticationRequired: "Sign-in is required to continue."
        case .guestAuthenticationFailed: "The development Mac did not accept its SSH credentials."
        case .credentialsLocked: "The credentials needed for this operation are locked."
        case .executableUnavailable: "A required tool is missing or could not be launched."
        case .permissionDenied: "Guesthouse does not have the required access."
        case .insufficientDiskSpace: "There is not enough disk space for this operation."
        case .verificationFailed: "A required integrity or trust check failed."
        case .invalidResponse: "A tool returned an unsupported or incomplete response."
        case .processFailed: "The tool reported a failure."
        case .outcomeUnknown: "The operation's outcome could not be confirmed."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .unsupportedHost:
            "Open Settings and check the supported Mac architecture, macOS release and resource requirements."
        case .timedOut, .processFailed, .outcomeUnknown:
            "Inspect the development Mac's current state before trying the operation again."
        case .connectionFailed:
            "Check that the development Mac is running and its SSH connection is available."
        case .authenticationRequired:
            "Open Accounts and sign in again."
        case .guestAuthenticationFailed:
            "Open the development Mac console to check the guest account. Resume pairing with the correct guest-only password, or use Repair for key-based access. Keep the pinned host identity; do not bypass verification."
        case .credentialsLocked:
            "Unlock the Keychain used by this operation, then check account readiness."
        case .executableUnavailable:
            "Open Repair and check the required tool installation."
        case .permissionDenied:
            "Review the access requested by this operation in Settings."
        case .insufficientDiskSpace:
            "Free disk space, then check the environment before retrying."
        case .verificationFailed:
            "Use Repair to inspect the resource or connection used by this operation; do not bypass verification."
        case .invalidResponse:
            "Check tool compatibility in Repair and inspect the environment before retrying."
        }
    }
}

extension DiagnosticFailure: LocalizedError {
    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recoveryMessage }
}
