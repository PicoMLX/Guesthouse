/// Version of the on-disk record formats produced by this package.
///
/// Bump `current` whenever a persisted record changes shape; the state store uses the
/// value to select a migration (MVP-PLAN.md §3, "Application components").
public struct SchemaVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    /// Versions start at 1, so a zero or negative one is refused here as well as at decoding:
    /// a record cannot be written carrying a version no reader will accept.
    public init?(_ rawValue: Int) {
        guard rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }

    private init(valid rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The version written by this build.
    public static let current = SchemaVersion(valid: 1)

    /// What a document written before versioning is: it carries no version key at all. A
    /// migration is keyed on this. It is never written: encoding it fails, so a record cannot
    /// come to carry a version no reader would accept.
    public static let unversioned = SchemaVersion(valid: 0)

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
        self = SchemaVersion(valid: value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        // The unversioned sentinel describes a document that predates versioning; writing it
        // would produce a record every reader, including this one, refuses.
        guard rawValue > 0 else {
            throw EncodingError.invalidValue(rawValue, EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "the unversioned sentinel is not a version a record can carry"
            ))
        }
        try container.encode(rawValue)
    }
}
