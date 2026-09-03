import Foundation

/// The versioned list of combinations Guesthouse has tested, shipped with the app
/// (MVP-PLAN.md §10, Phase 2: "Keep a versioned compatibility manifest").
///
/// A tested tuple is not the same as a verified one. A tested entry supports a range of host
/// macOS versions; its `verification`, if any, names the exact host version and build on
/// which a real Codex desktop connection was recorded, and only that exact host counts.
public struct CompatibilityManifest: Codable, Hashable, Sendable {
    public var schemaVersion: SchemaVersion
    /// Monotonic manifest revision, independent of the record schema.
    public var manifestVersion: Int
    public var notes: String?
    public var tested: [TestedTuple]
    public var incompatibilities: [KnownIncompatibility]

    public init(
        schemaVersion: SchemaVersion = .current,
        manifestVersion: Int,
        notes: String? = nil,
        tested: [TestedTuple],
        incompatibilities: [KnownIncompatibility] = []
    ) {
        self.schemaVersion = schemaVersion
        self.manifestVersion = manifestVersion
        self.notes = notes
        self.tested = tested
        self.incompatibilities = incompatibilities
    }

    /// Evidence of a real desktop connection for one exact host, attached to a tested entry.
    public struct Verification: Codable, Hashable, Sendable {
        public var verifiedAt: Date
        public var hostMacOSVersion: SemanticVersion
        public var hostMacOSBuild: String
        /// Where the evidence lives, for example `docs/phase0/compat.md`.
        public var evidence: String

        public init(verifiedAt: Date, hostMacOSVersion: SemanticVersion, hostMacOSBuild: String, evidence: String) {
            self.verifiedAt = verifiedAt
            self.hostMacOSVersion = hostMacOSVersion
            self.hostMacOSBuild = hostMacOSBuild
            self.evidence = evidence
        }

        public func covers(_ tuple: CompatibilityTuple) -> Bool {
            hostMacOSVersion == tuple.hostMacOSVersion && hostMacOSBuild == tuple.hostMacOSBuild
        }
    }

    /// One tested combination. Host macOS is a range; every other field is exact.
    public struct TestedTuple: Codable, Hashable, Sendable {
        public var hostMacOS: VersionRange
        public var codexDesktopVersion: String
        public var codexDesktopBuild: String
        public var runtimeProtocolVersion: Int
        public var tartVersion: String
        public var guestMacOSBuild: String
        public var xcodeBuild: String
        public var codexCLIVersion: String
        public var codexCLIPath: String
        public var codexCLICapabilities: [String]
        public var githubCLIVersion: String
        public var provisioningScriptVersion: String
        /// Present only when a real desktop connection was recorded, and then only for the exact
        /// host it names.
        public var verification: Verification?

        public init(
            hostMacOS: VersionRange,
            codexDesktopVersion: String,
            codexDesktopBuild: String,
            runtimeProtocolVersion: Int,
            tartVersion: String,
            guestMacOSBuild: String,
            xcodeBuild: String,
            codexCLIVersion: String,
            codexCLIPath: String,
            codexCLICapabilities: [String] = [],
            githubCLIVersion: String,
            provisioningScriptVersion: String,
            verification: Verification? = nil
        ) {
            self.hostMacOS = hostMacOS
            self.codexDesktopVersion = codexDesktopVersion
            self.codexDesktopBuild = codexDesktopBuild
            self.runtimeProtocolVersion = runtimeProtocolVersion
            self.tartVersion = tartVersion
            self.guestMacOSBuild = guestMacOSBuild
            self.xcodeBuild = xcodeBuild
            self.codexCLIVersion = codexCLIVersion
            self.codexCLIPath = codexCLIPath
            self.codexCLICapabilities = codexCLICapabilities.sorted()
            self.githubCLIVersion = githubCLIVersion
            self.provisioningScriptVersion = provisioningScriptVersion
            self.verification = verification
        }

        public var isVerified: Bool { verification != nil }

        /// Whether the observed combination is one this entry was tested with. A single CLI
        /// installation is part of the tested condition.
        public func matches(_ tuple: CompatibilityTuple) -> Bool {
            hostMacOS.contains(tuple.hostMacOSVersion)
                && codexDesktopVersion == tuple.codexDesktopVersion
                && codexDesktopBuild == tuple.codexDesktopBuild
                && runtimeProtocolVersion == tuple.runtimeProtocolVersion
                && tartVersion == tuple.tartVersion
                && guestMacOSBuild == tuple.guestMacOSBuild
                && xcodeBuild == tuple.xcodeBuild
                && codexCLIVersion == tuple.codexCLIVersion
                && codexCLIPath == tuple.codexCLIPath
                && tuple.codexCLIInstallations == 1
                && codexCLICapabilities == tuple.codexCLICapabilities
                && githubCLIVersion == tuple.githubCLIVersion
                && provisioningScriptVersion == tuple.provisioningScriptVersion
        }
    }

    /// A combination known not to work. Every specified field must match the observed value
    /// for the rule to apply; an unknown observed field never triggers it.
    public struct KnownIncompatibility: Codable, Hashable, Sendable {
        public var hostMacOS: VersionRange?
        public var hostMacOSBuild: String?
        public var codexDesktopVersion: String?
        public var codexDesktopBuild: String?
        public var runtimeProtocolVersion: Int?
        public var tartVersion: String?
        public var guestMacOSBuild: String?
        public var xcodeBuild: String?
        public var codexCLIVersion: String?
        public var githubCLIVersion: String?
        public var provisioningScriptVersion: String?
        public var reason: String

        public init(
            hostMacOS: VersionRange? = nil,
            hostMacOSBuild: String? = nil,
            codexDesktopVersion: String? = nil,
            codexDesktopBuild: String? = nil,
            runtimeProtocolVersion: Int? = nil,
            tartVersion: String? = nil,
            guestMacOSBuild: String? = nil,
            xcodeBuild: String? = nil,
            codexCLIVersion: String? = nil,
            githubCLIVersion: String? = nil,
            provisioningScriptVersion: String? = nil,
            reason: String
        ) {
            self.hostMacOS = hostMacOS
            self.hostMacOSBuild = hostMacOSBuild
            self.codexDesktopVersion = codexDesktopVersion
            self.codexDesktopBuild = codexDesktopBuild
            self.runtimeProtocolVersion = runtimeProtocolVersion
            self.tartVersion = tartVersion
            self.guestMacOSBuild = guestMacOSBuild
            self.xcodeBuild = xcodeBuild
            self.codexCLIVersion = codexCLIVersion
            self.githubCLIVersion = githubCLIVersion
            self.provisioningScriptVersion = provisioningScriptVersion
            self.reason = reason
        }

        public func applies(to observed: ObservedTuple) -> Bool {
            func check<T: Equatable>(_ rule: T?, _ value: T?) -> Bool {
                guard let rule else { return true }
                guard let value else { return false }
                return rule == value
            }
            let hostInRange: Bool
            if let hostMacOS {
                guard let version = observed.hostMacOSVersion else { return false }
                hostInRange = hostMacOS.contains(version)
            } else {
                hostInRange = true
            }
            return hostInRange
                && check(hostMacOSBuild, observed.hostMacOSBuild)
                && check(codexDesktopVersion, observed.codexDesktopVersion)
                && check(codexDesktopBuild, observed.codexDesktopBuild)
                && check(runtimeProtocolVersion, observed.runtimeProtocolVersion)
                && check(tartVersion, observed.tartVersion)
                && check(guestMacOSBuild, observed.guestMacOSBuild)
                && check(xcodeBuild, observed.xcodeBuild)
                && check(codexCLIVersion, observed.codexCLIVersion)
                && check(githubCLIVersion, observed.githubCLIVersion)
                && check(provisioningScriptVersion, observed.provisioningScriptVersion)
        }
    }

    /// The manifest shipped inside this package.
    public static func bundled() throws -> CompatibilityManifest {
        guard let url = Bundle.module.url(forResource: "compatibility-manifest", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(from: try Data(contentsOf: url))
    }

    public static func decode(from data: Data) throws -> CompatibilityManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CompatibilityManifest.self, from: data)
    }
}
