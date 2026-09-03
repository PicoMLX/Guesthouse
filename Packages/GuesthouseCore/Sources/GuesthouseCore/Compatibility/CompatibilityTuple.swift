/// The components whose combination decides whether a Codex handoff is known to work
/// (MVP-PLAN.md §5, "Connect-time compatibility, not only update-time checks").
public enum CompatibilityField: String, Codable, Hashable, Sendable, CaseIterable {
    case hostMacOSVersion
    case codexDesktopVersion
    case codexDesktopBuild
    case runtimeProtocolVersion
    case tartVersion
    case guestMacOSBuild
    case xcodeBuild
    case codexCLIVersion
    case githubCLIVersion
    case provisioningScriptVersion
}

/// A fully known combination. Every field has a value.
public struct CompatibilityTuple: Codable, Hashable, Sendable {
    public var hostMacOSVersion: SemanticVersion
    public var codexDesktopVersion: String
    public var codexDesktopBuild: String
    public var runtimeProtocolVersion: Int
    public var tartVersion: String
    public var guestMacOSBuild: String
    public var xcodeBuild: String
    public var codexCLIVersion: String
    public var githubCLIVersion: String
    public var provisioningScriptVersion: String

    public init(
        hostMacOSVersion: SemanticVersion,
        codexDesktopVersion: String,
        codexDesktopBuild: String,
        runtimeProtocolVersion: Int,
        tartVersion: String,
        guestMacOSBuild: String,
        xcodeBuild: String,
        codexCLIVersion: String,
        githubCLIVersion: String,
        provisioningScriptVersion: String
    ) {
        self.hostMacOSVersion = hostMacOSVersion
        self.codexDesktopVersion = codexDesktopVersion
        self.codexDesktopBuild = codexDesktopBuild
        self.runtimeProtocolVersion = runtimeProtocolVersion
        self.tartVersion = tartVersion
        self.guestMacOSBuild = guestMacOSBuild
        self.xcodeBuild = xcodeBuild
        self.codexCLIVersion = codexCLIVersion
        self.githubCLIVersion = githubCLIVersion
        self.provisioningScriptVersion = provisioningScriptVersion
    }

    /// The fields whose values differ between two tuples.
    public func differences(from other: CompatibilityTuple) -> [CompatibilityField] {
        var changed: [CompatibilityField] = []
        if hostMacOSVersion != other.hostMacOSVersion { changed.append(.hostMacOSVersion) }
        if codexDesktopVersion != other.codexDesktopVersion { changed.append(.codexDesktopVersion) }
        if codexDesktopBuild != other.codexDesktopBuild { changed.append(.codexDesktopBuild) }
        if runtimeProtocolVersion != other.runtimeProtocolVersion { changed.append(.runtimeProtocolVersion) }
        if tartVersion != other.tartVersion { changed.append(.tartVersion) }
        if guestMacOSBuild != other.guestMacOSBuild { changed.append(.guestMacOSBuild) }
        if xcodeBuild != other.xcodeBuild { changed.append(.xcodeBuild) }
        if codexCLIVersion != other.codexCLIVersion { changed.append(.codexCLIVersion) }
        if githubCLIVersion != other.githubCLIVersion { changed.append(.githubCLIVersion) }
        if provisioningScriptVersion != other.provisioningScriptVersion { changed.append(.provisioningScriptVersion) }
        return changed
    }
}

/// What was actually observed at connect time. `nil` means unknown, and unknown is never
/// treated as matching anything: the plan requires reporting "unknown" rather than guessing.
public struct ObservedTuple: Codable, Hashable, Sendable {
    public var hostMacOSVersion: SemanticVersion?
    public var codexDesktopVersion: String?
    public var codexDesktopBuild: String?
    public var runtimeProtocolVersion: Int?
    public var tartVersion: String?
    public var guestMacOSBuild: String?
    public var xcodeBuild: String?
    public var codexCLIVersion: String?
    public var githubCLIVersion: String?
    public var provisioningScriptVersion: String?

    public init(
        hostMacOSVersion: SemanticVersion? = nil,
        codexDesktopVersion: String? = nil,
        codexDesktopBuild: String? = nil,
        runtimeProtocolVersion: Int? = nil,
        tartVersion: String? = nil,
        guestMacOSBuild: String? = nil,
        xcodeBuild: String? = nil,
        codexCLIVersion: String? = nil,
        githubCLIVersion: String? = nil,
        provisioningScriptVersion: String? = nil
    ) {
        self.hostMacOSVersion = hostMacOSVersion
        self.codexDesktopVersion = codexDesktopVersion
        self.codexDesktopBuild = codexDesktopBuild
        self.runtimeProtocolVersion = runtimeProtocolVersion
        self.tartVersion = tartVersion
        self.guestMacOSBuild = guestMacOSBuild
        self.xcodeBuild = xcodeBuild
        self.codexCLIVersion = codexCLIVersion
        self.githubCLIVersion = githubCLIVersion
        self.provisioningScriptVersion = provisioningScriptVersion
    }

    public init(_ tuple: CompatibilityTuple) {
        self.init(
            hostMacOSVersion: tuple.hostMacOSVersion,
            codexDesktopVersion: tuple.codexDesktopVersion,
            codexDesktopBuild: tuple.codexDesktopBuild,
            runtimeProtocolVersion: tuple.runtimeProtocolVersion,
            tartVersion: tuple.tartVersion,
            guestMacOSBuild: tuple.guestMacOSBuild,
            xcodeBuild: tuple.xcodeBuild,
            codexCLIVersion: tuple.codexCLIVersion,
            githubCLIVersion: tuple.githubCLIVersion,
            provisioningScriptVersion: tuple.provisioningScriptVersion
        )
    }

    /// The fields that are unknown.
    public var unknownFields: [CompatibilityField] {
        var unknown: [CompatibilityField] = []
        if hostMacOSVersion == nil { unknown.append(.hostMacOSVersion) }
        if codexDesktopVersion == nil { unknown.append(.codexDesktopVersion) }
        if codexDesktopBuild == nil { unknown.append(.codexDesktopBuild) }
        if runtimeProtocolVersion == nil { unknown.append(.runtimeProtocolVersion) }
        if tartVersion == nil { unknown.append(.tartVersion) }
        if guestMacOSBuild == nil { unknown.append(.guestMacOSBuild) }
        if xcodeBuild == nil { unknown.append(.xcodeBuild) }
        if codexCLIVersion == nil { unknown.append(.codexCLIVersion) }
        if githubCLIVersion == nil { unknown.append(.githubCLIVersion) }
        if provisioningScriptVersion == nil { unknown.append(.provisioningScriptVersion) }
        return unknown
    }

    /// The fully known tuple, or `nil` if any field is unknown.
    public var exact: CompatibilityTuple? {
        guard let hostMacOSVersion, let codexDesktopVersion, let codexDesktopBuild,
              let runtimeProtocolVersion, let tartVersion, let guestMacOSBuild, let xcodeBuild,
              let codexCLIVersion, let githubCLIVersion, let provisioningScriptVersion
        else { return nil }
        return CompatibilityTuple(
            hostMacOSVersion: hostMacOSVersion,
            codexDesktopVersion: codexDesktopVersion,
            codexDesktopBuild: codexDesktopBuild,
            runtimeProtocolVersion: runtimeProtocolVersion,
            tartVersion: tartVersion,
            guestMacOSBuild: guestMacOSBuild,
            xcodeBuild: xcodeBuild,
            codexCLIVersion: codexCLIVersion,
            githubCLIVersion: githubCLIVersion,
            provisioningScriptVersion: provisioningScriptVersion
        )
    }
}
