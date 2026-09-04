import GuesthouseCore

/// Pure mapping from Lume discovery outcomes to the public XPC contract. Keeping policy here
/// makes every externally visible state testable without launching the embedded service.
public enum LumeDiscoveryReport {
    /// Keeps discovery logging useful without inspecting an error description whose associated
    /// values may contain paths, process details, or credentials. The type name still crosses
    /// Guesthouse's normal redaction and bounding boundary before it becomes public log text.
    public static func redactedDiagnostic(for error: any Error) -> SanitizedText {
        SanitizedText(String(describing: type(of: error)))
    }

    public static let checking = RuntimeVersionInfo.LumeRuntimeInfo(
        version: nil,
        verified: false
    )

    public static func storageUnavailable(_ error: RuntimeStorageError) -> RuntimeVersionInfo.LumeRuntimeInfo {
        let problem: RuntimeStorageProblem
        switch error {
        case .protectionDrift(let path, let reason):
            problem = RuntimeStorageProblem(kind: .protectionDrift, path: path, detail: reason)
        case .insecureDirectory(let path, let reason):
            problem = RuntimeStorageProblem(kind: .insecureDirectory, path: path, detail: reason)
        case .unwritable(let path, let reason):
            problem = RuntimeStorageProblem(kind: .unwritable, path: path, detail: reason.value)
        }
        return .init(
            version: nil,
            verified: false,
            problem: .runtimeStorageUnavailable(problem)
        )
    }

    public static let missing = RuntimeVersionInfo.LumeRuntimeInfo(
        version: nil,
        verified: false,
        problem: .runtimeMissing
    )

    public static func rejectedBundle(_ error: LumeVerificationError) -> RuntimeVersionInfo.LumeRuntimeInfo {
        guard case .versionMismatch(let found) = error else {
            return .init(version: nil, verified: false, problem: .runtimeProbeFailed)
        }
        return .init(
            version: found.value,
            verified: false,
            problem: .runtimeIncompatible(found: found, required: LumePin.version.description)
        )
    }

    public static func succeeded(_ result: LumeProbeResult) -> RuntimeVersionInfo.LumeRuntimeInfo {
        .init(
            version: result.version.description,
            verified: true,
            capabilities: result.capabilities
        )
    }

    public static func failedProbe(
        _ error: any Error,
        claimedVersion: SemanticVersion
    ) -> RuntimeVersionInfo.LumeRuntimeInfo {
        if let storageError = error as? RuntimeStorageError {
            return storageUnavailable(storageError)
        }
        if case .versionMismatch(let found, let required) = error as? LumeInvocationError {
            return .init(
                version: found.description,
                verified: true,
                problem: .runtimeIncompatible(
                    found: SanitizedText(found.description),
                    required: required.description
                )
            )
        }
        let trustInvalidated: Bool
        switch error as? LumeInvocationError {
        case .bundleChanged?, .storageMismatch?: trustInvalidated = true
        default: trustInvalidated = false
        }
        return .init(
            version: trustInvalidated ? nil : claimedVersion.description,
            verified: !trustInvalidated,
            problem: .runtimeProbeFailed
        )
    }
}
