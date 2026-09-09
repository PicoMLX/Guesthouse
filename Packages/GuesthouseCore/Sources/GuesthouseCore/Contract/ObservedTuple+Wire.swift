extension ObservedTuple {
    /// Preserve exact valid private identity, or mark the offending field unknown. Never
    /// truncate, redact, hash, or manufacture replacement identity (MVP-PLAN.md §5, ADR 0003).
    /// The transport must separately bound encoded bytes before decoding any status.
    func admittedForWire() -> Self {
        var result = self
        let versions: [WritableKeyPath<Self, String?>] = [
            \.codexDesktopVersion, \.codexDesktopBuild, \.runtimeVersion, \.codexCLIVersion, \.githubCLIVersion
        ]
        for key in versions {
            if let value = result[keyPath: key], !ConnectionVerificationRecord.isVersionIdentifier(value) {
                result[keyPath: key] = nil
            }
        }
        let builds: [WritableKeyPath<Self, String?>] = [\.hostMacOSBuild, \.guestMacOSBuild, \.xcodeBuild]
        for key in builds {
            if let value = result[keyPath: key], !ConnectionVerificationRecord.isBuildIdentifier(value) {
                result[keyPath: key] = nil
            }
        }
        for key in [\Self.codexDesktopPath, \Self.codexCLIPath] {
            if let value = result[keyPath: key], !ConnectionVerificationRecord.isResolvedPath(value) {
                result[keyPath: key] = nil
            }
        }
        if let value = result.provisioningScriptVersion,
           !ConnectionVerificationRecord.isIdentifier(value, punctuation: [43, 45, 46]) {
            result.provisioningScriptVersion = nil
        }
        if let values = result.codexCLICapabilities,
           values.count > CompatibilityTuple.maximumCapabilities
            || !values.allSatisfy({ ConnectionVerificationRecord.isIdentifier($0, punctuation: [45, 46, 58, 95]) }) {
            result.codexCLICapabilities = nil
        }
        if let version = result.runtimeProtocolVersion, version <= 0 { result.runtimeProtocolVersion = nil }
        if let count = result.codexCLIInstallations, count < 0 { result.codexCLIInstallations = nil }
        // Zero and competing installation counts are valid adverse observations. Preserve
        // them so the evaluator explains missing/ambiguous tools, not merely unknown fields.
        return result
    }
}
