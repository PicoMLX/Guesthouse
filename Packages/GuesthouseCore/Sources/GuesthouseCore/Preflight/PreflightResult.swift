public enum PreflightCheckKind: String, Codable, Hashable, Sendable, CaseIterable {
    case architecture, macOSVersion, memory, freeDisk, codexDesktop
}

/// Closed facts replace #61's arbitrary detail strings (ADR 0003). The check kind and
/// severity are derived, so a decoded unknown disk cannot be relabeled as a passing check.
public enum PreflightResult: Codable, Hashable, Sendable {
    case architectureSupported(CPUArchitecture)
    case architectureUnknown
    case architectureMismatch(found: CPUArchitecture, required: CPUArchitecture)
    case macOSSupported(SemanticVersion)
    case macOSUnknown
    case macOSTooOld(found: SemanticVersion, minimum: SemanticVersion)
    case memorySufficient(bytes: UInt64)
    case memoryLimited(foundBytes: UInt64, recommendedBytes: UInt64)
    case memoryUnknown
    case memoryFailure(GuesthouseError)
    case diskSufficient(bytes: UInt64)
    case insufficientDisk(requiredBytes: UInt64, availableBytes: UInt64)
    case diskUnavailable(HostProbeError)
    case codexInstalled(version: SemanticVersion?, build: SemanticVersion?)
    case codexNotFound
    case codexUnavailable

    public enum Severity: String, Codable, Hashable, Sendable {
        case pass, warn, undetermined, fail
    }

    public var kind: PreflightCheckKind {
        switch self {
        case .architectureSupported, .architectureUnknown, .architectureMismatch: .architecture
        case .macOSSupported, .macOSUnknown, .macOSTooOld: .macOSVersion
        case .memorySufficient, .memoryLimited, .memoryUnknown, .memoryFailure: .memory
        case .diskSufficient, .insufficientDisk, .diskUnavailable: .freeDisk
        case .codexInstalled, .codexNotFound, .codexUnavailable: .codexDesktop
        }
    }

    public var severity: Severity {
        switch self {
        case .architectureSupported, .macOSSupported, .memorySufficient, .diskSufficient, .codexInstalled: .pass
        case .memoryLimited, .codexNotFound: .warn
        case .macOSUnknown, .memoryUnknown, .diskUnavailable, .codexUnavailable: .undetermined
        case .architectureUnknown, .architectureMismatch, .macOSTooOld, .memoryFailure, .insufficientDisk: .fail
        }
    }

    public var isBlocking: Bool { severity == .fail || severity == .undetermined }

    /// Fixed templates and typed numeric observations only, not a diagnostic-history input.
    public var userMessage: String {
        switch self {
        case .architectureSupported(let architecture):
            "Processor: \(Self.name(architecture))."
        case .architectureUnknown:
            GuesthouseError.unsupportedHost(.unknownArchitecture).userMessage
        case .architectureMismatch(let found, let required):
            "This Mac uses \(Self.name(found)); the selected policy requires \(Self.name(required))."
        case .macOSSupported(let version):
            "macOS \(version) meets the selected host version requirement."
        case .macOSUnknown:
            "Guesthouse could not determine this Mac's macOS version. Check again before starting setup."
        case .macOSTooOld(let found, let minimum):
            "This Mac runs macOS \(found); macOS \(minimum) or later is required."
        case .memorySufficient(let bytes):
            "This Mac has \(bytes) bytes of memory and meets the recommendation."
        case .memoryLimited(let found, let recommended):
            "This Mac has \(found) bytes of memory; \(recommended) bytes are recommended. Run one development Mac at a time and expect memory pressure during large builds."
        case .memoryUnknown:
            "Guesthouse could not determine this Mac's memory. Check again before starting setup."
        case .memoryFailure(let error):
            error.userMessage
        case .diskSufficient(let bytes):
            "The selected runtime storage volume has \(bytes) bytes available for the planned setup."
        case .insufficientDisk(let required, let available):
            GuesthouseError.insufficientDisk(requiredBytes: required, availableBytes: available).userMessage
        case .diskUnavailable(let error):
            error.userMessage
        case .codexInstalled(let version, let build):
            "Codex desktop is installed. Version: \(version?.description ?? "unknown"); build: \(build?.description ?? "unknown"). Connection compatibility still needs verification."
        case .codexNotFound:
            "Codex desktop is not installed. Guesthouse can prepare a development Mac without it, but opening a workspace in Codex will require it."
        case .codexUnavailable:
            "Guesthouse could not check whether Codex desktop is installed. Check again before continuing."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .architectureSupported, .macOSSupported, .memorySufficient, .memoryLimited,
             .diskSufficient, .codexInstalled, .codexNotFound: []
        case .architectureUnknown, .architectureMismatch, .macOSTooOld: [.openSettings, .cancel]
        case .macOSUnknown, .memoryUnknown, .codexUnavailable: [.retry, .cancel]
        case .memoryFailure(let error): error.recoveryActions
        case .insufficientDisk(let required, let available):
            GuesthouseError.insufficientDisk(requiredBytes: required, availableBytes: available).recoveryActions
        case .diskUnavailable(let error): error.recoveryActions
        }
    }

    private static func name(_ architecture: CPUArchitecture) -> String {
        switch architecture {
        case .appleSilicon: "Apple silicon"
        case .intel: "Intel"
        case .unknown: "an unknown processor architecture"
        }
    }
}
