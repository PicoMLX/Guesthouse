import Foundation

/// The versioned list of combinations Guesthouse has tested, shipped with the app
/// (MVP-PLAN.md §10, Phase 2: "Keep a versioned compatibility manifest").
///
/// A tested tuple is not the same as a verified one. `verified` is set only when a phase-0
/// or release run recorded a real Codex desktop connection for exactly that combination.
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
        public var githubCLIVersion: String
        public var provisioningScriptVersion: String
        /// Present only when a real desktop connection was recorded for this exact combination.
        public var verifiedAt: Date?
        /// Where the evidence lives, for example `docs/phase0/compat.md`.
        public var evidence: String?

        public init(
            hostMacOS: VersionRange,
            codexDesktopVersion: String,
            codexDesktopBuild: String,
            runtimeProtocolVersion: Int,
            tartVersion: String,
            guestMacOSBuild: String,
            xcodeBuild: String,
            codexCLIVersion: String,
            githubCLIVersion: String,
            provisioningScriptVersion: String,
            verifiedAt: Date? = nil,
            evidence: String? = nil
        ) {
            self.hostMacOS = hostMacOS
            self.codexDesktopVersion = codexDesktopVersion
            self.codexDesktopBuild = codexDesktopBuild
            self.runtimeProtocolVersion = runtimeProtocolVersion
            self.tartVersion = tartVersion
            self.guestMacOSBuild = guestMacOSBuild
            self.xcodeBuild = xcodeBuild
            self.codexCLIVersion = codexCLIVersion
            self.githubCLIVersion = githubCLIVersion
            self.provisioningScriptVersion = provisioningScriptVersion
            self.verifiedAt = verifiedAt
            self.evidence = evidence
        }

        public var isVerified: Bool { verifiedAt != nil }

        public func matches(_ tuple: CompatibilityTuple) -> Bool {
            hostMacOS.contains(tuple.hostMacOSVersion)
                && codexDesktopVersion == tuple.codexDesktopVersion
                && codexDesktopBuild == tuple.codexDesktopBuild
                && runtimeProtocolVersion == tuple.runtimeProtocolVersion
                && tartVersion == tuple.tartVersion
                && guestMacOSBuild == tuple.guestMacOSBuild
                && xcodeBuild == tuple.xcodeBuild
                && codexCLIVersion == tuple.codexCLIVersion
                && githubCLIVersion == tuple.githubCLIVersion
                && provisioningScriptVersion == tuple.provisioningScriptVersion
        }
    }

    /// A combination known not to work. Every specified field must equal the observed value
    /// for the rule to apply; an unknown observed field never triggers it.
    public struct KnownIncompatibility: Codable, Hashable, Sendable {
        public var codexDesktopVersion: String?
        public var codexDesktopBuild: String?
        public var runtimeProtocolVersion: Int?
        public var tartVersion: String?
        public var guestMacOSBuild: String?
        public var xcodeBuild: String?
        public var codexCLIVersion: String?
        public var githubCLIVersion: String?
        public var reason: String

        public init(
            codexDesktopVersion: String? = nil,
            codexDesktopBuild: String? = nil,
            runtimeProtocolVersion: Int? = nil,
            tartVersion: String? = nil,
            guestMacOSBuild: String? = nil,
            xcodeBuild: String? = nil,
            codexCLIVersion: String? = nil,
            githubCLIVersion: String? = nil,
            reason: String
        ) {
            self.codexDesktopVersion = codexDesktopVersion
            self.codexDesktopBuild = codexDesktopBuild
            self.runtimeProtocolVersion = runtimeProtocolVersion
            self.tartVersion = tartVersion
            self.guestMacOSBuild = guestMacOSBuild
            self.xcodeBuild = xcodeBuild
            self.codexCLIVersion = codexCLIVersion
            self.githubCLIVersion = githubCLIVersion
            self.reason = reason
        }

        public func applies(to observed: ObservedTuple) -> Bool {
            func check<T: Equatable>(_ rule: T?, _ value: T?) -> Bool {
                guard let rule else { return true }
                guard let value else { return false }
                return rule == value
            }
            return check(codexDesktopVersion, observed.codexDesktopVersion)
                && check(codexDesktopBuild, observed.codexDesktopBuild)
                && check(runtimeProtocolVersion, observed.runtimeProtocolVersion)
                && check(tartVersion, observed.tartVersion)
                && check(guestMacOSBuild, observed.guestMacOSBuild)
                && check(xcodeBuild, observed.xcodeBuild)
                && check(codexCLIVersion, observed.codexCLIVersion)
                && check(githubCLIVersion, observed.githubCLIVersion)
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
