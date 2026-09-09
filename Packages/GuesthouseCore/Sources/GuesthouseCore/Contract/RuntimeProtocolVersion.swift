/// Shared GUI/service wire epoch, separate from persistence and diagnostic-export schemas.
public struct RuntimeProtocolVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) { self.rawValue = rawValue }

    /// Epoch 12 activates bounded native frames and structured diagnostics on both endpoints.
    /// Historical prototypes used 1–11. None is a compatible production fallback (ADR 0003).
    public static let current = RuntimeProtocolVersion(12)

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
