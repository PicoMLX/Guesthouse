import Foundation

/// Typed reasons adapted from retained #61. No path or underlying error can become the
/// message, encoded payload or recovery text (ADR 0003). The concrete probe stays in RuntimeKit.
public enum HostProbeError: String, Error, Codable, Hashable, Sendable, LocalizedError, CaseIterable {
    case storageRootUnknown
    case volumeUnavailable
    case volumeIdentityChanged
    case notADirectory
    case destinationNotWritable
    case capacityUnavailable

    public var userMessage: String {
        switch self {
        case .storageRootUnknown:
            "Guesthouse could not determine this account's runtime storage location. Check again before starting setup."
        case .volumeUnavailable:
            "The volume selected for the development Mac is unavailable. Reconnect it before checking again."
        case .volumeIdentityChanged:
            "The storage location no longer refers to the selected volume. Inspect the original volume before continuing."
        case .notADirectory:
            "The development Mac's storage location is not a folder. Inspect the location before starting setup."
        case .destinationNotWritable:
            "Guesthouse's runtime cannot write to the development Mac's storage folder. Check the folder's permissions and volume access."
        case .capacityUnavailable:
            "Guesthouse could not determine available disk space. Check again before downloading or importing files."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .storageRootUnknown, .capacityUnavailable: [.retry, .openSettings, .cancel]
        case .volumeUnavailable: [.retry, .inspectState, .cancel]
        case .volumeIdentityChanged: [.inspectState, .cancel]
        case .notADirectory: [.inspectState, .openSettings, .cancel]
        case .destinationNotWritable: [.openSettings, .retry, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryActions.map(\.title).joined(separator: "; ") }
}
