import Foundation

/// Proof that Codex desktop really opened a guest workspace with an exact combination
/// of versions (MVP-PLAN.md §5: "Record connection verification for that exact tuple only
/// after the real desktop flow succeeds").
///
/// A record can only be created from `DesktopConnectionEvidence`. Version queries such as
/// `codex --version` are not evidence and have no way to produce one.
public struct ConnectionVerificationRecord: Hashable, Sendable {
    /// Record-level schema version, so the state store can migrate history when the tuple
    /// changes shape instead of misreading old evidence under a new schema.
    public let schemaVersion: SchemaVersion
    public let tuple: CompatibilityTuple
    public let verifiedAt: Date
    public let evidence: DesktopConnectionEvidence

    /// - Throws: `CompatibilityRecordError.implausibleObservation` when a guest-reported string
    ///   is empty, too long, carries control or format characters, or is something the
    ///   redactor would change: such an observation is never written to persisted history.
    public init(tuple: CompatibilityTuple, verifiedAt: Date, evidence: DesktopConnectionEvidence) throws(CompatibilityRecordError) {
        try Self.validate(tuple)
        schemaVersion = .current
        self.tuple = tuple
        self.verifiedAt = verifiedAt
        self.evidence = evidence
    }

    public static let maximumObservationLength = 256

    /// Every string in the tuple must be a plausible version, build, or path.
    public static func validate(_ tuple: CompatibilityTuple) throws(CompatibilityRecordError) {
        let fields: [(CompatibilityField, [String])] = [
            (.hostMacOSBuild, [tuple.hostMacOSBuild]), (.codexDesktopVersion, [tuple.codexDesktopVersion]),
            (.codexDesktopBuild, [tuple.codexDesktopBuild]), (.codexDesktopPath, [tuple.codexDesktopPath]),
            (.tartVersion, [tuple.tartVersion]), (.guestMacOSBuild, [tuple.guestMacOSBuild]), (.xcodeBuild, [tuple.xcodeBuild]),
            (.codexCLIVersion, [tuple.codexCLIVersion]), (.codexCLIPath, [tuple.codexCLIPath]),
            (.codexCLICapabilities, tuple.codexCLICapabilities), (.githubCLIVersion, [tuple.githubCLIVersion]),
            (.provisioningScriptVersion, [tuple.provisioningScriptVersion]),
        ]
        for (field, values) in fields {
            for value in values where !isPlausibleObservation(value) {
                throw .implausibleObservation(field)
            }
        }
    }

    static func isPlausibleObservation(_ value: String) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= maximumObservationLength else { return false }
        let clean = value.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: false
            default: true
            }
        }
        return clean && Redactor().redact(fieldValue: value) == value
    }
}

public enum CompatibilityRecordError: Error, Hashable, Sendable, LocalizedError {
    /// A guest-reported value did not look like a version, build, or path.
    case implausibleObservation(CompatibilityField)

    public var userMessage: String {
        switch self {
        case .implausibleObservation(let field):
            "The development Mac reported a \(field.rawValue) value that does not look like a version, build, or path, so this connection was not recorded. Check the tools on the development Mac before trying again."
        }
    }

    public var recoveryActions: [RecoveryAction] { [.inspectState, .repair(.tools), .cancel] }
    public var errorDescription: String? { userMessage }
}

extension ConnectionVerificationRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tuple, verifiedAt, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        // Exactly the current schema until an explicit migration exists: an older or newer
        // record would otherwise be interpreted under a shape it was never written in.
        guard version == SchemaVersion.current else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "record schema \(version) is not \(SchemaVersion.current)")
        }
        schemaVersion = version
        tuple = try container.decode(CompatibilityTuple.self, forKey: .tuple)
        verifiedAt = try container.decode(Date.self, forKey: .verifiedAt)
        evidence = try container.decode(DesktopConnectionEvidence.self, forKey: .evidence)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tuple, forKey: .tuple)
        try container.encode(verifiedAt, forKey: .verifiedAt)
        try container.encode(evidence, forKey: .evidence)
    }
}

/// How a real desktop connection was confirmed.
public enum DesktopConnectionEvidence: Codable, Hashable, Sendable {
    /// The user confirmed in the GUI that the workspace opened in Codex desktop. This is the
    /// expected path while no machine-readable connection status exists.
    case userConfirmedWorkspaceOpened
    /// A supported, machine-readable status from the desktop application. Record its source
    /// so a future change in that interface is visible in diagnostics.
    case machineReadableStatus(source: String)
}
