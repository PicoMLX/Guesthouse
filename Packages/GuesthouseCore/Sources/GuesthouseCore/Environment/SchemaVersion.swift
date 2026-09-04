/// Version of the on-disk record formats produced by this package.
///
/// Bump `current` whenever a persisted record changes shape; the state store uses the
/// value to select a migration (MVP-PLAN.md §3, "Application components").
public struct SchemaVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The version written by this build.
    public static let current = SchemaVersion(1)

    public static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "v\(rawValue)" }
}

extension SchemaVersion: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        // Versions start at 1. Zero or a negative number is not an older format anyone can
        // migrate from; it is a corrupt record, and reading it as the current layout would
        // hide that.
        guard value > 0 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "schema version must be positive, found \(value)")
        }
        rawValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
