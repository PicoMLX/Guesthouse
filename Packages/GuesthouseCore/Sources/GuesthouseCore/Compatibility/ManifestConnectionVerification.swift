import Foundation

/// Evidence of a real desktop connection for one exact host, attached to a tested entry.
public struct ManifestConnectionVerification: Codable, Hashable, Sendable {
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
        guard text.utf8.prefix(129).count <= 128 else {
            throw DecodingError.dataCorruptedError(forKey: .verifiedAt, in: c, debugDescription: "not a supported ISO 8601 date")
        }
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
