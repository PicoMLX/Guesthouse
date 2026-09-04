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
    ///   `.implausibleEvidenceSource` when the evidence names its source the same way.
    public init(tuple: CompatibilityTuple, verifiedAt: Date, evidence: DesktopConnectionEvidence) throws(CompatibilityRecordError) {
        try Self.validate(tuple)
        try Self.validate(evidence)
        schemaVersion = .current
        self.tuple = tuple
        self.verifiedAt = verifiedAt
        self.evidence = evidence
    }

    public static let maximumObservationLength = 256
    /// A full path is bounded by the file system, not by the shape of a version string: a
    /// deeply nested but entirely valid bundle or executable must still be recordable.
    public static let maximumPathLength = 1024

    /// Every string in the tuple must be a plausible version, build, or path.
    public static func validate(_ tuple: CompatibilityTuple) throws(CompatibilityRecordError) {
        let fields: [(CompatibilityField, [String], Int)] = [
            (.hostMacOSBuild, [tuple.hostMacOSBuild], maximumObservationLength),
            (.codexDesktopVersion, [tuple.codexDesktopVersion], maximumObservationLength),
            (.codexDesktopBuild, [tuple.codexDesktopBuild], maximumObservationLength),
            (.codexDesktopPath, [tuple.codexDesktopPath], maximumPathLength),
            (.tartVersion, [tuple.tartVersion], maximumObservationLength),
            (.guestMacOSBuild, [tuple.guestMacOSBuild], maximumObservationLength),
            (.xcodeBuild, [tuple.xcodeBuild], maximumObservationLength),
            (.codexCLIVersion, [tuple.codexCLIVersion], maximumObservationLength),
            (.codexCLIPath, [tuple.codexCLIPath], maximumPathLength),
            (.codexCLICapabilities, tuple.codexCLICapabilities, maximumObservationLength),
            (.githubCLIVersion, [tuple.githubCLIVersion], maximumObservationLength),
            (.provisioningScriptVersion, [tuple.provisioningScriptVersion], maximumObservationLength),
        ]
        for (field, values, limit) in fields {
            for value in values where !isPlausibleObservation(value, limit: limit) {
                throw .implausibleObservation(field)
            }
        }
    }

    /// The evidence names where a machine-readable status came from, and that name is written
    /// to persisted history too, so it is held to the same bar as the tuple's strings.
    public static func validate(_ evidence: DesktopConnectionEvidence) throws(CompatibilityRecordError) {
        guard case .machineReadableStatus(let source) = evidence else { return }
        guard isPlausibleObservation(source) else { throw .implausibleEvidenceSource }
    }

    static func isPlausibleObservation(_ value: String, limit: Int = maximumObservationLength) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= limit else { return false }
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
    /// The evidence named a source that does not look like an interface name.
    case implausibleEvidenceSource

    public var userMessage: String {
        switch self {
        case .implausibleObservation(let field):
            "The development Mac reported a \(field.rawValue) value that does not look like a version, build, or path, so this connection was not recorded. Check the tools on the development Mac before trying again."
        case .implausibleEvidenceSource:
            "The Codex desktop app reported a connection status whose source does not look like an interface name, so this connection was not recorded. Check the tools on the development Mac before trying again."
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
        let tuple = try container.decode(CompatibilityTuple.self, forKey: .tuple)
        let evidence = try container.decode(DesktopConnectionEvidence.self, forKey: .evidence)
        // History on disk is as untrusted as the probe that first produced it: an implausible
        // value must not become verification evidence by having survived one round trip.
        try Self.validate(tuple)
        try Self.validate(evidence)
        self.tuple = tuple
        self.evidence = evidence
        verifiedAt = try container.decode(Date.self, forKey: .verifiedAt)
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
