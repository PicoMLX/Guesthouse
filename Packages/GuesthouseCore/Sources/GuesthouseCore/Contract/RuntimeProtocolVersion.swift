/// Version of the message contract between the GUI and the GuesthouseRuntime XPC service.
///
/// Bump on any change a peer from the previous version could misread. Both sides send it in
/// every envelope, and the service refuses a mismatch with `GuesthouseError.protocolMismatch`.
public struct RuntimeProtocolVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Version 3 adds encoded Lume discovery failures and gives runtime-storage failures a
    /// typed, sanitized payload. Version 2 added `InvalidRequestReason.tooManyInFlight`;
    /// peers that disagree must not decode each other.
    public static let current = RuntimeProtocolVersion(3)

    public static func < (lhs: RuntimeProtocolVersion, rhs: RuntimeProtocolVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

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
