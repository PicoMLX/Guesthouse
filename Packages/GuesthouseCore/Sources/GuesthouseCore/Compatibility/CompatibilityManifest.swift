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
        /// Rounded at construction to the precision the encoded form carries, so a value and
        /// its own decoded form compare equal and hash alike.
        public let verifiedAt: Date
        public let hostMacOSVersion: SemanticVersion
        public let hostMacOSBuild: String
        /// Where the evidence lives, for example `docs/phase0/compat.md`.
        public let evidence: String

        public init(verifiedAt: Date, hostMacOSVersion: SemanticVersion, hostMacOSBuild: String, evidence: String) {
            self.verifiedAt = Self.encodablePrecision(verifiedAt)
            self.hostMacOSVersion = hostMacOSVersion
            self.hostMacOSBuild = hostMacOSBuild
            self.evidence = evidence
        }

        /// The instant `verifiedAt` becomes once encoded. A `Date` carries far more precision
        /// than the encoded form does, and keeping the extra digits would mean a value that
        /// never compares equal to itself after a round trip.
        private static func encodablePrecision(_ date: Date) -> Date {
            Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded())
        }

        /// `verifiedAt` has one fixed representation, an ISO 8601 string in whole seconds,
        /// whatever encoder or decoder is used, so a manifest produced with `JSONEncoder`
        /// reads back through `decode(from:)`. Whole seconds because `ISO8601FormatStyle`'s
        /// fractional seconds do not survive their own round trip, and when a connection was
        /// recorded is not a sub-second fact. A document written with fractional seconds still
        /// decodes; it is rounded like any other input.
        private enum CodingKeys: String, CodingKey { case verifiedAt, hostMacOSVersion, hostMacOSBuild, evidence }
        private static let dateStyle = Date.ISO8601FormatStyle()

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let text = try c.decode(String.self, forKey: .verifiedAt)
            guard let date = (try? Self.dateStyle.parse(text)) ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) else {
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
    ///
    /// Immutable throughout: `verification` names evidence for the combination the other fields
    /// spell out, so editing one field in place would leave the evidence attached to a
    /// combination it never covered. Replacing the whole entry states the pairing again.
    public struct TestedTuple: Codable, Hashable, Sendable {
        public let hostMacOS: VersionRange
        public let codexDesktopVersion: String
        public let codexDesktopBuild: String
        public let codexDesktopPath: String
        public let runtimeProtocolVersion: Int
        public let tartVersion: String
        public let guestMacOSBuild: String
        public let xcodeBuild: String
        public let codexCLIVersion: String
        public let codexCLIPath: String
        public let codexCLICapabilities: [String]
        public let githubCLIVersion: String
        public let provisioningScriptVersion: String
        /// Present only when a real desktop connection was recorded, and then only for the exact
        /// host it names.
        public let verification: Verification?

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
                // Required, never defaulted: a manifest that omits the key is stale rather than
                // one that reports a CLI with no capabilities, and the difference decides matches.
                codexCLICapabilities: try c.decode([String].self, forKey: .codexCLICapabilities),
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
                && codexCLICapabilities == CompatibilityTuple.normalize(tuple.codexCLICapabilities)
                && githubCLIVersion == tuple.githubCLIVersion
                && provisioningScriptVersion == tuple.provisioningScriptVersion
        }
    }

    /// A combination known not to work. Every specified field must match the observed value
    /// for the rule to apply; an unknown observed field never triggers it. A rule can single
    /// out one CLI executable, one capability set, or one desktop bundle, so a broken
    /// installation can be blocked without blocking a working one of the same version.
    ///
    /// Immutable throughout: a rule blocks handoff, and the evaluator hands its `reason` and
    /// `recoveryActions` straight to the GUI, so both invariants below have to survive from
    /// construction to the moment the rule fires.
    public struct KnownIncompatibility: Codable, Hashable, Sendable {
        /// What stays available when a rule fires: the console, work export, and stopping the
        /// environment (the persistent stop control is never an error button).
        public static let defaultRecoveryActions: [RecoveryAction] = [.openConsole, .exportWork, .cancel]

        public let hostMacOS: VersionRange?
        public let hostMacOSBuild: String?
        public let codexDesktopVersion: String?
        public let codexDesktopBuild: String?
        public let codexDesktopPath: String?
        public let runtimeProtocolVersion: Int?
        public let tartVersion: String?
        public let guestMacOSBuild: String?
        public let xcodeBuild: String?
        public let codexCLIVersion: String?
        public let codexCLIPath: String?
        /// Matches when the observed capability list, normalized, equals this list.
        public let codexCLICapabilities: [String]?
        public let githubCLIVersion: String?
        public let provisioningScriptVersion: String?
        /// Why handoff is blocked, in the user's words. Never empty.
        public let reason: String
        /// What the GUI offers when this rule fires. Never empty.
        public let recoveryActions: [RecoveryAction]

        /// - Precondition: `reason` is not empty or whitespace only. A rule that blocks handoff
        ///   without saying why leaves the GUI with a button and no explanation.
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
            precondition(!Self.isBlank(reason), "an incompatibility rule must explain itself")
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

        private static func isBlank(_ text: String) -> Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let reason = try c.decode(String.self, forKey: .reason)
            guard !Self.isBlank(reason) else {
                throw DecodingError.dataCorruptedError(forKey: .reason, in: c, debugDescription: "an incompatibility rule must explain itself")
            }
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
                reason: reason,
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
                // The rule's list is normalized at construction; an observation assembled field
                // by field need not be, and order must never decide whether a rule fires.
                && check(codexCLICapabilities, observed.codexCLICapabilities.map(CompatibilityTuple.normalize))
                && check(githubCLIVersion, observed.githubCLIVersion)
                && check(provisioningScriptVersion, observed.provisioningScriptVersion)
        }
    }

    /// Refuses any schema this build cannot interpret: a newer document may carry a
    /// compatibility dimension this evaluator would silently ignore. The check lives here so
    /// that a plain `JSONDecoder().decode(CompatibilityManifest.self, from:)` enforces it too.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(SchemaVersion.self, forKey: .schemaVersion)
        guard schemaVersion == SchemaVersion.current else {
            throw CompatibilityManifestError.unsupportedSchema(found: schemaVersion, supported: .current)
        }
        self.init(
            schemaVersion: schemaVersion,
            manifestVersion: try c.decode(Int.self, forKey: .manifestVersion),
            notes: try c.decodeIfPresent(String.self, forKey: .notes),
            tested: try c.decode([TestedTuple].self, forKey: .tested),
            incompatibilities: try c.decode([KnownIncompatibility].self, forKey: .incompatibilities)
        )
    }

    /// The manifest shipped inside this package.
    public static func bundled() throws -> CompatibilityManifest {
        guard let url = Bundle.module.url(forResource: "compatibility-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            throw CompatibilityManifestError.unreadableManifest
        }
        return try decode(from: data)
    }

    /// Decodes a manifest, reporting every failure as something the user can act on rather than
    /// as a raw decoding fault: the only manifest the app reads is one it shipped with, so a
    /// failure here means the installation, not the document, is wrong.
    public static func decode(from data: Data) throws -> CompatibilityManifest {
        do {
            return try JSONDecoder().decode(CompatibilityManifest.self, from: data)
        } catch let error as CompatibilityManifestError {
            throw error
        } catch {
            throw CompatibilityManifestError.malformedManifest
        }
    }
}

public enum CompatibilityManifestError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedSchema(found: SchemaVersion, supported: SchemaVersion)
    /// The shipped resource is missing from the bundle or could not be read.
    case unreadableManifest
    /// The document is not a compatibility manifest this build can parse. What was found is
    /// deliberately not quoted; resource content does not belong in a user-facing message.
    case malformedManifest

    public var userMessage: String {
        switch self {
        case .unsupportedSchema(let found, let supported):
            "The compatibility list shipped with this copy of Guesthouse uses format \(found.rawValue), which this version reads as \(supported.rawValue). The app and its resources do not match; reinstall Guesthouse."
        case .unreadableManifest:
            "The compatibility list shipped with this copy of Guesthouse is missing or cannot be read. The installation is damaged; reinstall Guesthouse."
        case .malformedManifest:
            "The compatibility list shipped with this copy of Guesthouse is not a list this version can read. The installation is damaged; reinstall Guesthouse."
        }
    }

    public var recoveryActions: [RecoveryAction] { [.reinstallApp, .cancel] }
    public var errorDescription: String? { userMessage }
}
