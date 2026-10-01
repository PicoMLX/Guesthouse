import Foundation
import GuesthouseCore

/// Closed failures migrated from #83 for ADR 0003. Never carry paths, discovered metadata,
/// entitlement names or arbitrary framework descriptions into presentation/diagnostics.
enum LumeVerificationError: Error, Hashable, Sendable, CaseIterable, LocalizedError {
    case bundleMissing, insecureBundleLayout, infoPlistUnreadable
    case bundleIdentifierMismatch, versionMismatch, executableNameMismatch
    case executableMissing, executableUnreadable, executableDigestMismatch
    case signatureInvalid, requirementNotMet, codeDirectoryHashMismatch
    case teamIdentifierMismatch, signingIdentifierMismatch, entitlementMismatch
    case archiveUnreadable, digestMismatch

    var userMessage: String {
        switch self {
        case .bundleMissing:
            "The tested Lume runtime is missing from Guesthouse's private runtime folder."
        case .insecureBundleLayout:
            "The Lume runtime has an unsafe file layout. Cancel and preserve the existing runtime and VM disks for inspection."
        case .infoPlistUnreadable, .bundleIdentifierMismatch, .versionMismatch, .executableNameMismatch:
            "The installed Lume runtime does not match the tested app metadata."
        case .executableMissing, .executableUnreadable, .executableDigestMismatch:
            "The installed Lume executable is missing, unreadable, or differs from the tested release."
        case .signatureInvalid, .requirementNotMet, .codeDirectoryHashMismatch,
             .teamIdentifierMismatch, .signingIdentifierMismatch, .entitlementMismatch:
            "The installed Lume runtime does not have the tested code-signing identity and capabilities."
        case .archiveUnreadable:
            "The downloaded Lume archive cannot be read."
        case .digestMismatch:
            "The downloaded Lume archive differs from the tested release."
        }
    }
    var recoveryActions: [RecoveryAction] {
        self == .insecureBundleLayout ? [.cancel] : [.repair(.runtime), .cancel]
    }
    var errorDescription: String? { userMessage }
}
