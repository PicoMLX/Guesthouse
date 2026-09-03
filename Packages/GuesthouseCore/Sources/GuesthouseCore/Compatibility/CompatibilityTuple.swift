/// The components whose combination decides whether a Codex handoff is known to work
/// (MVP-PLAN.md §5, "Connect-time compatibility, not only update-time checks").
///
/// Host macOS is tracked as both a product version and a build: a build replacement that keeps
/// the product version is still OS drift (§4). The Codex desktop app is tracked by version,
/// build, and the selected bundle's path, so a replaced or re-selected bundle that reports the
/// same version is still a change (§5). The Codex CLI is tracked by version, resolved
/// login-shell path, number of competing installations, and reported capabilities, because the
/// same version string can belong to a different executable (§5).
public enum CompatibilityField: String, Codable, Hashable, Sendable, CaseIterable {
    case hostMacOSVersion
    case hostMacOSBuild
    case codexDesktopVersion
    case codexDesktopBuild
    case codexDesktopPath
    case runtimeProtocolVersion
    case tartVersion
    case guestMacOSBuild
    case xcodeBuild
    case codexCLIVersion
    case codexCLIPath
    case codexCLIInstallations
    case codexCLICapabilities
    case githubCLIVersion
    case provisioningScriptVersion
}

/// A fully known combination. Every field has a value.
public struct CompatibilityTuple: Codable, Hashable, Sendable {
    public var hostMacOSVersion: SemanticVersion
    public var hostMacOSBuild: String
    public var codexDesktopVersion: String
    public var codexDesktopBuild: String
    /// The selected desktop application bundle, resolved.
    public var codexDesktopPath: String
    public var runtimeProtocolVersion: Int
    public var tartVersion: String
    public var guestMacOSBuild: String
    public var xcodeBuild: String
    public var codexCLIVersion: String
    /// The executable the guest login shell resolves, as reported by `which -a codex`.
    public var codexCLIPath: String
    /// How many `codex` executables the login shell can see. Anything but 1 is ambiguous.
    public var codexCLIInstallations: Int
    /// Capability identifiers the CLI reports, sorted and without duplicates. Empty when it
    /// reports none.
    public var codexCLICapabilities: [String]
    public var githubCLIVersion: String
    public var provisioningScriptVersion: String

    public init(
        hostMacOSVersion: SemanticVersion,
        hostMacOSBuild: String,
        codexDesktopVersion: String,
        codexDesktopBuild: String,
        codexDesktopPath: String,
        runtimeProtocolVersion: Int,
        tartVersion: String,
        guestMacOSBuild: String,
        xcodeBuild: String,
        codexCLIVersion: String,
        codexCLIPath: String,
        codexCLIInstallations: Int,
        codexCLICapabilities: [String],
        githubCLIVersion: String,
        provisioningScriptVersion: String
    ) {
        self.hostMacOSVersion = hostMacOSVersion
        self.hostMacOSBuild = hostMacOSBuild
        self.codexDesktopVersion = codexDesktopVersion
        self.codexDesktopBuild = codexDesktopBuild
        self.codexDesktopPath = codexDesktopPath
        self.runtimeProtocolVersion = runtimeProtocolVersion
        self.tartVersion = tartVersion
        self.guestMacOSBuild = guestMacOSBuild
        self.xcodeBuild = xcodeBuild
        self.codexCLIVersion = codexCLIVersion
        self.codexCLIPath = codexCLIPath
        self.codexCLIInstallations = codexCLIInstallations
        self.codexCLICapabilities = Self.normalize(codexCLICapabilities)
        self.githubCLIVersion = githubCLIVersion
        self.provisioningScriptVersion = provisioningScriptVersion
    }

    /// Decoding goes through the initializer so a document with capabilities in another
    /// order or listed twice compares equal to the normalized form.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostMacOSVersion: try c.decode(SemanticVersion.self, forKey: .hostMacOSVersion),
            hostMacOSBuild: try c.decode(String.self, forKey: .hostMacOSBuild),
            codexDesktopVersion: try c.decode(String.self, forKey: .codexDesktopVersion),
            codexDesktopBuild: try c.decode(String.self, forKey: .codexDesktopBuild),
            codexDesktopPath: try c.decode(String.self, forKey: .codexDesktopPath),
            runtimeProtocolVersion: try c.decode(Int.self, forKey: .runtimeProtocolVersion),
            tartVersion: try c.decode(String.self, forKey: .tartVersion),
            guestMacOSBuild: try c.decode(String.self, forKey: .guestMacOSBuild),
            xcodeBuild: try c.decode(String.self, forKey: .xcodeBuild),
            codexCLIVersion: try c.decode(String.self, forKey: .codexCLIVersion),
            codexCLIPath: try c.decode(String.self, forKey: .codexCLIPath),
            codexCLIInstallations: try c.decode(Int.self, forKey: .codexCLIInstallations),
            codexCLICapabilities: try c.decode([String].self, forKey: .codexCLICapabilities),
            githubCLIVersion: try c.decode(String.self, forKey: .githubCLIVersion),
            provisioningScriptVersion: try c.decode(String.self, forKey: .provisioningScriptVersion)
        )
    }

    /// Sorted, without duplicates: the canonical form every comparison uses.
    public static func normalize(_ capabilities: [String]) -> [String] {
        Array(Set(capabilities)).sorted()
    }

    /// The fields whose values differ between two tuples.
    public func differences(from other: CompatibilityTuple) -> [CompatibilityField] {
        var changed: [CompatibilityField] = []
        if hostMacOSVersion != other.hostMacOSVersion { changed.append(.hostMacOSVersion) }
        if hostMacOSBuild != other.hostMacOSBuild { changed.append(.hostMacOSBuild) }
        if codexDesktopVersion != other.codexDesktopVersion { changed.append(.codexDesktopVersion) }
        if codexDesktopBuild != other.codexDesktopBuild { changed.append(.codexDesktopBuild) }
        if codexDesktopPath != other.codexDesktopPath { changed.append(.codexDesktopPath) }
        if runtimeProtocolVersion != other.runtimeProtocolVersion { changed.append(.runtimeProtocolVersion) }
        if tartVersion != other.tartVersion { changed.append(.tartVersion) }
        if guestMacOSBuild != other.guestMacOSBuild { changed.append(.guestMacOSBuild) }
        if xcodeBuild != other.xcodeBuild { changed.append(.xcodeBuild) }
        if codexCLIVersion != other.codexCLIVersion { changed.append(.codexCLIVersion) }
        if codexCLIPath != other.codexCLIPath { changed.append(.codexCLIPath) }
        if codexCLIInstallations != other.codexCLIInstallations { changed.append(.codexCLIInstallations) }
        if codexCLICapabilities != other.codexCLICapabilities { changed.append(.codexCLICapabilities) }
        if githubCLIVersion != other.githubCLIVersion { changed.append(.githubCLIVersion) }
        if provisioningScriptVersion != other.provisioningScriptVersion { changed.append(.provisioningScriptVersion) }
        return changed
    }
}

/// What was actually observed at connect time. `nil` means unknown, and unknown is never
/// treated as matching anything: the plan requires reporting "unknown" rather than guessing.
public struct ObservedTuple: Codable, Hashable, Sendable {
    public var hostMacOSVersion: SemanticVersion?
    public var hostMacOSBuild: String?
    public var codexDesktopVersion: String?
    public var codexDesktopBuild: String?
    public var codexDesktopPath: String?
    public var runtimeProtocolVersion: Int?
    public var tartVersion: String?
    public var guestMacOSBuild: String?
    public var xcodeBuild: String?
    public var codexCLIVersion: String?
    public var codexCLIPath: String?
    public var codexCLIInstallations: Int?
    public var codexCLICapabilities: [String]?
    public var githubCLIVersion: String?
    public var provisioningScriptVersion: String?

    public init(
        hostMacOSVersion: SemanticVersion? = nil,
        hostMacOSBuild: String? = nil,
        codexDesktopVersion: String? = nil,
        codexDesktopBuild: String? = nil,
        codexDesktopPath: String? = nil,
        runtimeProtocolVersion: Int? = nil,
        tartVersion: String? = nil,
        guestMacOSBuild: String? = nil,
        xcodeBuild: String? = nil,
        codexCLIVersion: String? = nil,
        codexCLIPath: String? = nil,
        codexCLIInstallations: Int? = nil,
        codexCLICapabilities: [String]? = nil,
        githubCLIVersion: String? = nil,
        provisioningScriptVersion: String? = nil
    ) {
        self.hostMacOSVersion = hostMacOSVersion
        self.hostMacOSBuild = hostMacOSBuild
        self.codexDesktopVersion = codexDesktopVersion
        self.codexDesktopBuild = codexDesktopBuild
        self.codexDesktopPath = codexDesktopPath
        self.runtimeProtocolVersion = runtimeProtocolVersion
        self.tartVersion = tartVersion
        self.guestMacOSBuild = guestMacOSBuild
        self.xcodeBuild = xcodeBuild
        self.codexCLIVersion = codexCLIVersion
        self.codexCLIPath = codexCLIPath
        self.codexCLIInstallations = codexCLIInstallations
        self.codexCLICapabilities = codexCLICapabilities.map(CompatibilityTuple.normalize)
        self.githubCLIVersion = githubCLIVersion
        self.provisioningScriptVersion = provisioningScriptVersion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostMacOSVersion: try c.decodeIfPresent(SemanticVersion.self, forKey: .hostMacOSVersion),
            hostMacOSBuild: try c.decodeIfPresent(String.self, forKey: .hostMacOSBuild),
            codexDesktopVersion: try c.decodeIfPresent(String.self, forKey: .codexDesktopVersion),
            codexDesktopBuild: try c.decodeIfPresent(String.self, forKey: .codexDesktopBuild),
            codexDesktopPath: try c.decodeIfPresent(String.self, forKey: .codexDesktopPath),
            runtimeProtocolVersion: try c.decodeIfPresent(Int.self, forKey: .runtimeProtocolVersion),
            tartVersion: try c.decodeIfPresent(String.self, forKey: .tartVersion),
            guestMacOSBuild: try c.decodeIfPresent(String.self, forKey: .guestMacOSBuild),
            xcodeBuild: try c.decodeIfPresent(String.self, forKey: .xcodeBuild),
            codexCLIVersion: try c.decodeIfPresent(String.self, forKey: .codexCLIVersion),
            codexCLIPath: try c.decodeIfPresent(String.self, forKey: .codexCLIPath),
            codexCLIInstallations: try c.decodeIfPresent(Int.self, forKey: .codexCLIInstallations),
            codexCLICapabilities: try c.decodeIfPresent([String].self, forKey: .codexCLICapabilities),
            githubCLIVersion: try c.decodeIfPresent(String.self, forKey: .githubCLIVersion),
            provisioningScriptVersion: try c.decodeIfPresent(String.self, forKey: .provisioningScriptVersion)
        )
    }

    public init(_ tuple: CompatibilityTuple) {
        self.init(
            hostMacOSVersion: tuple.hostMacOSVersion,
            hostMacOSBuild: tuple.hostMacOSBuild,
            codexDesktopVersion: tuple.codexDesktopVersion,
            codexDesktopBuild: tuple.codexDesktopBuild,
            codexDesktopPath: tuple.codexDesktopPath,
            runtimeProtocolVersion: tuple.runtimeProtocolVersion,
            tartVersion: tuple.tartVersion,
            guestMacOSBuild: tuple.guestMacOSBuild,
            xcodeBuild: tuple.xcodeBuild,
            codexCLIVersion: tuple.codexCLIVersion,
            codexCLIPath: tuple.codexCLIPath,
            codexCLIInstallations: tuple.codexCLIInstallations,
            codexCLICapabilities: tuple.codexCLICapabilities,
            githubCLIVersion: tuple.githubCLIVersion,
            provisioningScriptVersion: tuple.provisioningScriptVersion
        )
    }

    /// The fields that are unknown.
    public var unknownFields: [CompatibilityField] {
        var unknown: [CompatibilityField] = []
        if hostMacOSVersion == nil { unknown.append(.hostMacOSVersion) }
        if hostMacOSBuild == nil { unknown.append(.hostMacOSBuild) }
        if codexDesktopVersion == nil { unknown.append(.codexDesktopVersion) }
        if codexDesktopBuild == nil { unknown.append(.codexDesktopBuild) }
        if codexDesktopPath == nil { unknown.append(.codexDesktopPath) }
        if runtimeProtocolVersion == nil { unknown.append(.runtimeProtocolVersion) }
        if tartVersion == nil { unknown.append(.tartVersion) }
        if guestMacOSBuild == nil { unknown.append(.guestMacOSBuild) }
        if xcodeBuild == nil { unknown.append(.xcodeBuild) }
        if codexCLIVersion == nil { unknown.append(.codexCLIVersion) }
        if codexCLIPath == nil { unknown.append(.codexCLIPath) }
        if codexCLIInstallations == nil { unknown.append(.codexCLIInstallations) }
        if codexCLICapabilities == nil { unknown.append(.codexCLICapabilities) }
        if githubCLIVersion == nil { unknown.append(.githubCLIVersion) }
        if provisioningScriptVersion == nil { unknown.append(.provisioningScriptVersion) }
        return unknown
    }

    /// The fully known tuple, or `nil` if any field is unknown.
    public var exact: CompatibilityTuple? {
        guard let hostMacOSVersion, let hostMacOSBuild, let codexDesktopVersion, let codexDesktopBuild,
              let codexDesktopPath, let runtimeProtocolVersion, let tartVersion, let guestMacOSBuild, let xcodeBuild,
              let codexCLIVersion, let codexCLIPath, let codexCLIInstallations, let codexCLICapabilities,
              let githubCLIVersion, let provisioningScriptVersion
        else { return nil }
        return CompatibilityTuple(
            hostMacOSVersion: hostMacOSVersion,
            hostMacOSBuild: hostMacOSBuild,
            codexDesktopVersion: codexDesktopVersion,
            codexDesktopBuild: codexDesktopBuild,
            codexDesktopPath: codexDesktopPath,
            runtimeProtocolVersion: runtimeProtocolVersion,
            tartVersion: tartVersion,
            guestMacOSBuild: guestMacOSBuild,
            xcodeBuild: xcodeBuild,
            codexCLIVersion: codexCLIVersion,
            codexCLIPath: codexCLIPath,
            codexCLIInstallations: codexCLIInstallations,
            codexCLICapabilities: codexCLICapabilities,
            githubCLIVersion: githubCLIVersion,
            provisioningScriptVersion: provisioningScriptVersion
        )
    }
}
