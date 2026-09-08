import Foundation

/// MVP error contract (#7, ADR 0003): retain useful explanations, never raw error text.
/// Associated values are closed enums, app-owned identities and numeric facts. Versions,
/// paths, artifact names and parser diagnostics must not be copied into this payload.
public enum GuesthouseError: Error, Codable, Hashable, Sendable {
    case unsupportedHost(UnsupportedHostReason)
    case insufficientDisk(requiredBytes: UInt64, availableBytes: UInt64)
    case downloadVerificationFailed(check: VerificationCheck)
    case runtimeMissing, runtimeIncompatible
    case guestNotReachable(EnvironmentID), hostKeyChanged(EnvironmentID)
    case credentialsLocked(CredentialStore), loginExpired(Provider)
    case toolMismatch(tool: Tool), xcodeComponentsIncomplete
    case vmSlotUnavailable(maximum: Int)
    case operationOutcomeUnknown(OperationID)
    case unauthorizedCaller
    case protocolMismatch(client: Int, service: Int)
    case invalidRequest(InvalidRequestReason)
    case canceled

    public enum UnsupportedHostReason: Codable, Hashable, Sendable {
        case notAppleSilicon, unknownArchitecture, macOSTooOld
        case insufficientMemory(foundBytes: UInt64, minimumBytes: UInt64)
    }
    public enum VerificationCheck: String, Codable, Hashable, Sendable, CaseIterable {
        case digest, signature, size
    }
    public enum CredentialStore: String, Codable, Hashable, Sendable, CaseIterable {
        case hostKeychain, guestKeychain
    }
    public enum Provider: String, Codable, Hashable, Sendable, CaseIterable {
        case github, codex
    }
    public enum Tool: String, Codable, Hashable, Sendable, CaseIterable {
        case xcode, swift, git, githubCLI, codexCLI, ssh, vmRuntime

        fileprivate var displayName: String {
            switch self {
            case .xcode: "Xcode"
            case .swift: "Swift"
            case .git: "Git"
            case .githubCLI: "GitHub CLI"
            case .codexCLI: "Codex CLI"
            case .ssh: "SSH"
            case .vmRuntime: "virtual machine runtime"
            }
        }
    }
    public enum InvalidRequestReason: String, Codable, Hashable, Sendable, CaseIterable {
        case oversized, pathEscapesAllowedRoot, invalidVMName, unsupportedOperation, malformed

        fileprivate var message: String {
            switch self {
            case .oversized: "The request exceeds Guesthouse's supported size limit."
            case .pathEscapesAllowedRoot: "The request refers to a location outside the allowed workspace or environment."
            case .invalidVMName: "The request contains an invalid development Mac name."
            case .unsupportedOperation: "This version of Guesthouse does not support the requested operation."
            case .malformed: "The request is incomplete or has an invalid format."
            }
        }
    }
    public enum Category: String, Codable, Hashable, Sendable, CaseIterable {
        case host, storage, runtime, guest, credentials, tools, workflow, ipc, user
    }

    public var category: Category {
        switch self {
        case .unsupportedHost: .host
        case .insufficientDisk: .storage
        case .downloadVerificationFailed, .runtimeMissing, .runtimeIncompatible: .runtime
        case .guestNotReachable, .hostKeyChanged: .guest
        case .credentialsLocked, .loginExpired: .credentials
        case .toolMismatch(.vmRuntime): .runtime
        case .toolMismatch, .xcodeComponentsIncomplete: .tools
        case .vmSlotUnavailable, .operationOutcomeUnknown: .workflow
        case .unauthorizedCaller, .protocolMismatch, .invalidRequest: .ipc
        case .canceled: .user
        }
    }

    public var userMessage: String {
        switch self {
        case .unsupportedHost(.notAppleSilicon):
            "Guesthouse needs an Apple silicon Mac to run a macOS development VM."
        case .unsupportedHost(.unknownArchitecture):
            "Guesthouse could not determine whether this Mac supports a macOS development VM."
        case .unsupportedHost(.macOSTooOld):
            "This Mac's macOS version is older than the supported host release."
        case .unsupportedHost(.insufficientMemory(let found, let minimum)):
            "This Mac has \(found) bytes of memory; at least \(minimum) bytes are required."
        case .insufficientDisk(let required, let available):
            "The operation needs \(required) bytes of disk space; \(available) bytes are available."
        case .downloadVerificationFailed(let check):
            "The downloaded artifact failed its \(check == .digest ? "checksum" : check.rawValue) verification check."
        case .runtimeMissing:
            "The virtual machine runtime is not installed."
        case .runtimeIncompatible:
            "The installed virtual machine runtime is not a supported version."
        case .guestNotReachable:
            "The development Mac is not answering over the network."
        case .hostKeyChanged:
            "The development Mac presented a different SSH identity. Repair pairing before connecting."
        case .credentialsLocked(.hostKeychain):
            "This Mac's Keychain is locked and Guesthouse cannot access its saved credentials."
        case .credentialsLocked(.guestKeychain):
            "The development Mac's Keychain is locked and its tools cannot access their saved credentials."
        case .loginExpired(.github):
            "Your GitHub sign-in on the development Mac needs to be renewed."
        case .loginExpired(.codex):
            "Your Codex sign-in on the development Mac needs to be renewed."
        case .toolMismatch(let tool):
            "The required tool (\(tool.displayName)) is missing or incompatible."
        case .xcodeComponentsIncomplete:
            "Xcode is missing required development components."
        case .vmSlotUnavailable(let maximum):
            "All \(maximum) supported environment slots are in use, including stopped environments."
        case .operationOutcomeUnknown:
            "The operation may or may not have completed. Inspect the current state before continuing."
        case .unauthorizedCaller:
            "The runtime refused a caller that did not meet its authentication requirements."
        case .protocolMismatch(let client, let service):
            "The app (protocol \(client)) and runtime (protocol \(service)) are incompatible."
        case .invalidRequest(let reason):
            reason.message
        case .canceled:
            "The operation was canceled; any partial changes must be inspected before retrying."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unsupportedHost(.macOSTooOld): [.openSettings, .cancel]
        case .unsupportedHost: [.openSettings, .cancel]
        case .insufficientDisk: [.freeDiskSpace, .inspectState, .cancel]
        case .downloadVerificationFailed: [.repair(.download), .cancel]
        case .runtimeMissing, .runtimeIncompatible, .toolMismatch(.vmRuntime): [.repair(.runtime), .cancel]
        case .guestNotReachable: [.inspectState, .openConsole, .cancel]
        case .hostKeyChanged: [.repair(.sshPairing), .openConsole, .exportWork, .cancel]
        case .credentialsLocked(.guestKeychain): [.openConsole, .repair(.credentials), .cancel]
        case .credentialsLocked(.hostKeychain): [.openSettings, .cancel]
        case .loginExpired: [.signInAgain, .cancel]
        case .toolMismatch: [.repair(.tools), .openConsole, .exportWork, .cancel]
        case .xcodeComponentsIncomplete: [.repair(.xcodeComponents), .openConsole, .exportWork, .cancel]
        case .vmSlotUnavailable: [.exportWork, .deleteEnvironment, .cancel]
        case .operationOutcomeUnknown, .canceled, .invalidRequest: [.inspectState, .cancel]
        case .unauthorizedCaller: [.cancel]
        case .protocolMismatch: [.reinstallApp, .cancel]
        }
    }

    /// Retry is not offered from a generic error: callers must reconcile actual state first.
    public var isRetryable: Bool { recoveryActions.contains(.retry) }
    public var recoveryMessage: String { recoveryActions.map(\.title).joined(separator: "; ") }
}

extension GuesthouseError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }
    public var description: String { "\(category.rawValue): \(userMessage)" }
}
