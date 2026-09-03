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
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
