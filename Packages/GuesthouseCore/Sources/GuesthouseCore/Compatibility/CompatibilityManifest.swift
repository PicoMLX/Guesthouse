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

        /// `verifiedAt` has one fixed representation, an ISO 8601 string with fractional
        /// seconds, whatever encoder or decoder is used, so a manifest produced with
        /// `JSONEncoder` reads back through `decode(from:)`.
        private enum CodingKeys: String, CodingKey { case verifiedAt, hostMacOSVersion, hostMacOSBuild, evidence }
        private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let text = try c.decode(String.self, forKey: .verifiedAt)
            guard let date = (try? Self.dateStyle.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) else {
                throw DecodingError.dataCorruptedError(forKey: .verifiedAt, in: c, debugDescription: "not an ISO 8601 date")
            }
            self.init(
                verifiedAt: date,
                hostMacOSVersion: try c.decode(SemanticVersion.self, forKey: .hostMacOSVersion),
                hostMacOSBuild: try c.decode(String.self, forKey: .hostMacOSBuild),
                evidence: try c.decode(String.self, forKey: .evidence)
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Self.dateStyle.format(verifiedAt), forKey: .verifiedAt)
            try c.encode(hostMacOSVersion, forKey: .hostMacOSVersion)
            try c.encode(hostMacOSBuild, forKey: .hostMacOSBuild)
            try c.encode(evidence, forKey: .evidence)
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
        public var codexDesktopPath: String
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
            codexDesktopPath: String,
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
            self.codexDesktopPath = codexDesktopPath
            self.runtimeProtocolVersion = runtimeProtocolVersion
            self.tartVersion = tartVersion
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
            self.init(
                hostMacOS: try c.decode(VersionRange.self, forKey: .hostMacOS),
                codexDesktopVersion: try c.decode(String.self, forKey: .codexDesktopVersion),
                codexDesktopBuild: try c.decode(String.self, forKey: .codexDesktopBuild),
                codexDesktopPath: try c.decode(String.self, forKey: .codexDesktopPath),
                runtimeProtocolVersion: try c.decode(Int.self, forKey: .runtimeProtocolVersion),
                tartVersion: try c.decode(String.self, forKey: .tartVersion),
                guestMacOSBuild: try c.decode(String.self, forKey: .guestMacOSBuild),
                xcodeBuild: try c.decode(String.self, forKey: .xcodeBuild),
                codexCLIVersion: try c.decode(String.self, forKey: .codexCLIVersion),
                codexCLIPath: try c.decode(String.self, forKey: .codexCLIPath),
                codexCLICapabilities: try c.decodeIfPresent([String].self, forKey: .codexCLICapabilities) ?? [],
                githubCLIVersion: try c.decode(String.self, forKey: .githubCLIVersion),
                provisioningScriptVersion: try c.decode(String.self, forKey: .provisioningScriptVersion),
                verification: try c.decodeIfPresent(Verification.self, forKey: .verification)
            )
        }

        public var isVerified: Bool { verification != nil }

        /// Whether the observed combination is one this entry was tested with. A single CLI
        /// installation is part of the tested condition.
        public func matches(_ tuple: CompatibilityTuple) -> Bool {
            hostMacOS.contains(tuple.hostMacOSVersion)
                && codexDesktopVersion == tuple.codexDesktopVersion
                && codexDesktopBuild == tuple.codexDesktopBuild
                && codexDesktopPath == tuple.codexDesktopPath
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
    /// for the rule to apply; an unknown observed field never triggers it. A rule can single
    /// out one CLI executable, one capability set, or one desktop bundle, so a broken
    /// installation can be blocked without blocking a working one of the same version.
    public struct KnownIncompatibility: Codable, Hashable, Sendable {
        /// What stays available when a rule fires: the console, work export, and stopping the
        /// environment (the persistent stop control is never an error button).
        public static let defaultRecoveryActions: [RecoveryAction] = [.openConsole, .exportWork, .cancel]

        public var hostMacOS: VersionRange?
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
        /// Matches when the observed capability list, normalized, equals this list.
        public var codexCLICapabilities: [String]?
        public var githubCLIVersion: String?
        public var provisioningScriptVersion: String?
        public var reason: String
        /// What the GUI offers when this rule fires. Never empty.
        public var recoveryActions: [RecoveryAction]

        public init(
            hostMacOS: VersionRange? = nil,
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
            codexCLICapabilities: [String]? = nil,
            githubCLIVersion: String? = nil,
            provisioningScriptVersion: String? = nil,
            reason: String,
            recoveryActions: [RecoveryAction] = KnownIncompatibility.defaultRecoveryActions
        ) {
            self.hostMacOS = hostMacOS
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
            self.codexCLICapabilities = codexCLICapabilities.map(CompatibilityTuple.normalize)
            self.githubCLIVersion = githubCLIVersion
            self.provisioningScriptVersion = provisioningScriptVersion
            self.reason = reason
            self.recoveryActions = recoveryActions.isEmpty ? Self.defaultRecoveryActions : recoveryActions
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                hostMacOS: try c.decodeIfPresent(VersionRange.self, forKey: .hostMacOS),
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
                codexCLICapabilities: try c.decodeIfPresent([String].self, forKey: .codexCLICapabilities),
                githubCLIVersion: try c.decodeIfPresent(String.self, forKey: .githubCLIVersion),
                provisioningScriptVersion: try c.decodeIfPresent(String.self, forKey: .provisioningScriptVersion),
                reason: try c.decode(String.self, forKey: .reason),
                recoveryActions: try c.decodeIfPresent([RecoveryAction].self, forKey: .recoveryActions) ?? Self.defaultRecoveryActions
            )
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
                && check(codexDesktopPath, observed.codexDesktopPath)
                && check(runtimeProtocolVersion, observed.runtimeProtocolVersion)
                && check(tartVersion, observed.tartVersion)
                && check(guestMacOSBuild, observed.guestMacOSBuild)
                && check(xcodeBuild, observed.xcodeBuild)
                && check(codexCLIVersion, observed.codexCLIVersion)
                && check(codexCLIPath, observed.codexCLIPath)
                && check(codexCLICapabilities, observed.codexCLICapabilities)
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

    /// Decodes a manifest and refuses any schema this build cannot interpret: a newer document
    /// may carry a compatibility dimension this evaluator would silently ignore.
    public static func decode(from data: Data) throws -> CompatibilityManifest {
        let manifest = try JSONDecoder().decode(CompatibilityManifest.self, from: data)
        guard manifest.schemaVersion == SchemaVersion.current else {
            throw CompatibilityManifestError.unsupportedSchema(found: manifest.schemaVersion, supported: .current)
        }
        return manifest
    }
}

public enum CompatibilityManifestError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedSchema(found: SchemaVersion, supported: SchemaVersion)

    public var userMessage: String {
        switch self {
        case .unsupportedSchema(let found, let supported):
            "The compatibility list shipped with this copy of Guesthouse uses format \(found.rawValue), which this version reads as \(supported.rawValue). The app and its resources do not match; reinstall Guesthouse."
        }
    }

    public var recoveryActions: [RecoveryAction] { [.reinstallApp, .cancel] }
    public var errorDescription: String? { userMessage }
}
