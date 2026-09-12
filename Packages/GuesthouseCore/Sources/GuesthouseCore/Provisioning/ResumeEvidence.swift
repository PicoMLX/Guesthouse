/// Durable partial work reported by inspection (MVP-PLAN.md §9, ADR 0003).
/// This operational record is not a diagnostic event or proof that an artifact is usable.
/// The runtime must revalidate identity, containment and resumability before using it.
public struct ResumeEvidence: Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case partialDownload, installationStaging, unfinishedCopy
    }

    public let kind: Kind
    /// A relative operational location, not display text or a host-path capability.
    /// Do not log or export it as diagnostics, or populate it from authentication output.
    public let stagingPath: String?
    public static let stagingPathByteLimit = 1_024

    /// Refuse a malformed path without repairing, truncating or silently dropping it.
    public init?(kind: Kind, stagingPath: String? = nil) {
        guard stagingPath.map(Self.isValidStagingPath) ?? true else { return nil }
        self.kind = kind
        self.stagingPath = stagingPath
    }

    /// Only these fixed templates reach presentation; no raw summary is accepted or stored.
    public var summary: String {
        switch kind {
        case .partialDownload: "An interrupted download has partial data to inspect before resuming."
        case .installationStaging: "An interrupted installation has staging data to inspect before resuming."
        case .unfinishedCopy: "An interrupted copy has partial data to inspect before resuming."
        }
    }

    private static func isValidStagingPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= stagingPathByteLimit,
              !value.hasPrefix("/"), !value.hasPrefix("~") else { return false }
        guard !value.unicodeScalars.contains(where: { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: true
            default: false
            }
        }) else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

extension ResumeEvidence: Codable {
    private enum CodingKeys: String, CodingKey { case kind, stagingPath }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let path = try container.decodeIfPresent(String.self, forKey: .stagingPath)
        guard let evidence = Self(kind: kind, stagingPath: path) else {
            throw DecodingError.dataCorruptedError(
                forKey: .stagingPath, in: container, debugDescription: "invalid relative staging location"
            )
        }
        self = evidence
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(stagingPath, forKey: .stagingPath)
    }
}
