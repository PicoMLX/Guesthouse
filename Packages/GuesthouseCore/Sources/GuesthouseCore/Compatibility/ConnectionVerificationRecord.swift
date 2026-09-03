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

    public init(tuple: CompatibilityTuple, verifiedAt: Date, evidence: DesktopConnectionEvidence) {
        schemaVersion = .current
        self.tuple = tuple
        self.verifiedAt = verifiedAt
        self.evidence = evidence
    }
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
