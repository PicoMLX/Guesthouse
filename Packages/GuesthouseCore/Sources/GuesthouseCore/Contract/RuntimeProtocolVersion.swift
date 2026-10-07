/// Shared GUI/service wire epoch, separate from persistence and diagnostic-export schemas.
public struct RuntimeProtocolVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) { self.rawValue = rawValue }

    /// Epoch 19 distinguishes runtime diagnostic identities from app observations.
    /// App-only observation failures cannot be delivered as runtime events.
    /// Earlier epochs are not compatible fallbacks; GUI/service upgrade together (ADR 0003).
    public static let current = RuntimeProtocolVersion(19)

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "protocol \(rawValue)" }
}

extension RuntimeProtocolVersion: Codable {
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
