import Foundation

/// Observed help advertisements only (MVP §§3–4), never provider/readiness or cleanup proof.
/// The runtime must independently verify the executable and inspect every actual launch.
public struct RuntimeProbeAdvertisement: Codable, Hashable, Sendable {
    public let version: SemanticVersion
    public let unattendedTahoeAdvertised: Bool
    public let createRunAttachStorageAdvertised: Bool
    public let detachedRunAdvertised: Bool
    public let nativeAttachAdvertised: Bool

    public init(version: SemanticVersion, unattendedTahoeAdvertised: Bool,
                createRunAttachStorageAdvertised: Bool, detachedRunAdvertised: Bool,
                nativeAttachAdvertised: Bool) {
        self.version = version
        self.unattendedTahoeAdvertised = unattendedTahoeAdvertised
        self.createRunAttachStorageAdvertised = createRunAttachStorageAdvertised
        self.detachedRunAdvertised = detachedRunAdvertised
        self.nativeAttachAdvertised = nativeAttachAdvertised
    }
}

/// Closed presentation; no output, paths, error descriptions or fabricated operation IDs.
public enum RuntimeProbeFailure: Codable, Hashable, Sendable, LocalizedError {
    case runtimeMissing, verificationFailed, versionMismatch, storageUnavailable, unsafeStorage
    case inspectionRequired, invalidResponse, timedOut, processFailed(exitStatus: Int32), outcomeUnknown

    public var userMessage: String {
        switch self {
        case .runtimeMissing: "The tested runtime is missing from Guesthouse's private runtime folder."
        case .verificationFailed, .versionMismatch: "The runtime does not match Guesthouse's tested identity. Preserve the installation and inspect it in Repair."
        case .storageUnavailable: "Guesthouse could not access its saved runtime state. Preserve the storage and inspect it before continuing."
        case .unsafeStorage: "Guesthouse could not verify its storage protection. Preserve the folders and any unpublished work before continuing."
        case .inspectionRequired, .outcomeUnknown: "The runtime inspection has an unknown outcome. Preserve its storage and inspect the actual owned processes before continuing."
        case .invalidResponse: "The runtime inspection did not return a complete supported response. Inspect its retained launch before continuing."
        case .timedOut: "The runtime inspection exceeded its time limit. Inspect its actual outcome before another launch."
        case .processFailed: "The runtime inspection returned a failure. Inspect its retained launch before continuing."
        }
    }
    public var errorDescription: String? { userMessage }
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .runtimeMissing, .verificationFailed, .versionMismatch: [.inspectState, .repair(.runtime), .cancel]
        default: [.inspectState, .cancel]
        }
    }
    // These failures arise from an admitted launch and must preserve its terminal identity.
    fileprivate var requiresTerminalFailureEvent: Bool {
        switch self {
        case .versionMismatch, .invalidResponse, .timedOut, .processFailed: true
        default: false
        }
    }
    // Artifact admission refuses before the next intent and diagnostic emitter exist.
    fileprivate var isPrelaunchFailure: Bool {
        switch self {
        case .runtimeMissing, .verificationFailed: true
        default: false
        }
    }
    public var diagnosticOutcome: DiagnosticEvent.Outcome {
        switch self {
        case .runtimeMissing: .failed(.executableUnavailable)
        case .verificationFailed, .versionMismatch: .failed(.verificationFailed)
        case .invalidResponse: .failed(.invalidResponse)
        case .timedOut: .failed(.timedOut)
        case .processFailed(let status): .failed(.processFailed, exitStatus: status)
        default: .failed(.outcomeUnknown)
        }
    }
}

/// Bounded private reply data. Only its typed diagnostics may enter DiagnosticLog (ADR 0003).
/// Precheck refusals carry no invented ID; an empty trace does NOT establish that nothing ran.
/// Decoding this report grants no verification, signal, settlement or replacement authority.
public struct RuntimeProbeReport: Codable, Hashable, Sendable {
    public static let maximumDiagnosticCount = 8
    public let advertisements: RuntimeProbeAdvertisement?
    public let failure: RuntimeProbeFailure?
    public let diagnostics: [DiagnosticEvent]

    public init(advertisements: RuntimeProbeAdvertisement? = nil,
                failure: RuntimeProbeFailure? = nil, diagnostics: [DiagnosticEvent]) {
        self.advertisements = advertisements
        self.failure = failure
        self.diagnostics = diagnostics
    }

    public var isValid: Bool {
        guard (advertisements == nil) != (failure == nil),
              diagnostics.count <= Self.maximumDiagnosticCount, diagnostics.count.isMultiple(of: 2),
              diagnostics.allSatisfy({ $0.isRuntimeEvent && $0.operation == .verifyRuntime && $0.environmentID == nil }) else { return false }
        if case .processFailed(let status) = failure, !(1...255).contains(status) { return false }
        if advertisements != nil, diagnostics.count != Self.maximumDiagnosticCount { return false }
        var seen: Set<UUID> = []
        for index in stride(from: 0, to: diagnostics.count, by: 2) {
            let start = diagnostics[index], end = diagnostics[index + 1]
            guard start.outcome == .started, start.operationID == end.operationID,
                  seen.insert(start.operationID).inserted else { return false }
            if end.outcome != .succeeded {
                return failure?.isPrelaunchFailure != true
                    && (failure != .versionMismatch || index == 0)
                    && index == diagnostics.count - 2 && end.outcome == failure?.diagnosticOutcome
            }
        }
        return failure?.requiresTerminalFailureEvent != true
            && (failure?.isPrelaunchFailure != true || diagnostics.count < Self.maximumDiagnosticCount)
    }

    private enum CodingKeys: String, CodingKey { case advertisements, failure, diagnostics }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(advertisements: try c.decodeIfPresent(RuntimeProbeAdvertisement.self, forKey: .advertisements),
                  failure: try c.decodeIfPresent(RuntimeProbeFailure.self, forKey: .failure),
                  diagnostics: try c.decode([DiagnosticEvent].self, forKey: .diagnostics))
        guard isValid else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
    }
    public func encode(to encoder: any Encoder) throws {
        guard isValid else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(advertisements, forKey: .advertisements)
        try c.encodeIfPresent(failure, forKey: .failure)
        try c.encode(diagnostics, forKey: .diagnostics)
    }
}
