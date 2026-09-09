import Foundation

/// One tested combination. Host macOS is a range; every other field is exact.
///
/// Immutable throughout: `verification` names evidence for the combination the other fields
/// spell out, so editing one field in place would leave the evidence attached to a
/// combination it never covered. Replacing the whole entry states the pairing again.
public struct TestedCompatibilityTuple: Codable, Hashable, Sendable {
    public let hostMacOS: VersionRange
    public let codexDesktopVersion: String
    public let codexDesktopBuild: String
    public let codexDesktopPath: String
    public let runtimeProtocolVersion: Int
    public let runtimeProvider: VMProvider
    public let runtimeVersion: String
    public let guestMacOSBuild: String
    public let xcodeBuild: String
    public let codexCLIVersion: String
    public let codexCLIPath: String
    public let codexCLICapabilities: [String]
    public let githubCLIVersion: String
    public let provisioningScriptVersion: String
    /// Present only when a real desktop connection was recorded, and then only for the exact
    /// host it names.
    public let verification: ManifestConnectionVerification?

    public init(
        hostMacOS: VersionRange,
        codexDesktopVersion: String,
        codexDesktopBuild: String,
        codexDesktopPath: String,
        runtimeProtocolVersion: Int,
        runtimeProvider: VMProvider,
        runtimeVersion: String,
        guestMacOSBuild: String,
        xcodeBuild: String,
        codexCLIVersion: String,
        codexCLIPath: String,
        codexCLICapabilities: [String] = [],
        githubCLIVersion: String,
        provisioningScriptVersion: String,
        verification: ManifestConnectionVerification? = nil
    ) {
        self.hostMacOS = hostMacOS
        self.codexDesktopVersion = codexDesktopVersion
        self.codexDesktopBuild = codexDesktopBuild
        self.codexDesktopPath = codexDesktopPath
        self.runtimeProtocolVersion = runtimeProtocolVersion
        self.runtimeProvider = runtimeProvider
        self.runtimeVersion = runtimeVersion
        self.guestMacOSBuild = guestMacOSBuild
        self.xcodeBuild = xcodeBuild
        self.codexCLIVersion = codexCLIVersion
        self.codexCLIPath = codexCLIPath
        self.codexCLICapabilities = CompatibilityTuple.normalize(codexCLICapabilities)
        self.githubCLIVersion = githubCLIVersion
        self.provisioningScriptVersion = provisioningScriptVersion
        self.verification = verification
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let capabilities = try c.decode([String].self, forKey: .codexCLICapabilities)
        guard capabilities.count <= CompatibilityTuple.maximumCapabilities else {
            throw DecodingError.dataCorruptedError(forKey: .codexCLICapabilities, in: c, debugDescription: "too many capabilities")
        }
        self.init(
            hostMacOS: try c.decode(VersionRange.self, forKey: .hostMacOS),
            codexDesktopVersion: try c.decode(String.self, forKey: .codexDesktopVersion),
            codexDesktopBuild: try c.decode(String.self, forKey: .codexDesktopBuild),
            codexDesktopPath: try c.decode(String.self, forKey: .codexDesktopPath),
            runtimeProtocolVersion: try c.decode(Int.self, forKey: .runtimeProtocolVersion),
            runtimeProvider: try c.decode(VMProvider.self, forKey: .runtimeProvider),
            runtimeVersion: try c.decode(String.self, forKey: .runtimeVersion),
            guestMacOSBuild: try c.decode(String.self, forKey: .guestMacOSBuild),
            xcodeBuild: try c.decode(String.self, forKey: .xcodeBuild),
            codexCLIVersion: try c.decode(String.self, forKey: .codexCLIVersion),
            codexCLIPath: try c.decode(String.self, forKey: .codexCLIPath),
            // Required, never defaulted: a manifest that omits the key is stale rather than
            // one that reports a CLI with no capabilities, and the difference decides matches.
            codexCLICapabilities: capabilities,
            githubCLIVersion: try c.decode(String.self, forKey: .githubCLIVersion),
            provisioningScriptVersion: try c.decode(String.self, forKey: .provisioningScriptVersion),
            verification: try c.decodeIfPresent(ManifestConnectionVerification.self, forKey: .verification)
        )
    }

    public var isVerified: Bool { verification != nil }

    /// Whether the observed combination is one this entry was tested with. A single CLI
    /// installation is part of the tested condition.
    public func matches(_ tuple: CompatibilityTuple) -> Bool {
        // An invalid observation must never be approved by a similarly malformed entry.
        guard (try? ConnectionVerificationRecord.validate(tuple)) != nil else { return false }
        return hostMacOS.contains(tuple.hostMacOSVersion)
            && codexDesktopVersion == tuple.codexDesktopVersion
            && codexDesktopBuild == tuple.codexDesktopBuild
            && codexDesktopPath == tuple.codexDesktopPath
            && runtimeProtocolVersion == tuple.runtimeProtocolVersion
            && runtimeProvider == tuple.runtimeProvider
            && runtimeVersion == tuple.runtimeVersion
            && guestMacOSBuild == tuple.guestMacOSBuild
            && xcodeBuild == tuple.xcodeBuild
            && codexCLIVersion == tuple.codexCLIVersion
            && codexCLIPath == tuple.codexCLIPath
            && tuple.codexCLIInstallations == 1
            && codexCLICapabilities == CompatibilityTuple.normalize(tuple.codexCLICapabilities)
            && githubCLIVersion == tuple.githubCLIVersion
            && provisioningScriptVersion == tuple.provisioningScriptVersion
    }
}
