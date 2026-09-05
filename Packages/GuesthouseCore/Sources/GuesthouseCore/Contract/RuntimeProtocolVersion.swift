/// Version of the message contract between the GUI and the GuesthouseRuntime XPC service.
///
/// Bump on any change a peer from the previous version could misread. Both sides send it in
/// every envelope, and the service refuses a mismatch with `GuesthouseError.protocolMismatch`.
public struct RuntimeProtocolVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    // Version 6 adopts event envelopes on native XPC. Versions 2–5 were already used by
    // pre-envelope descendants; their independent payload additions must be reconciled.
    public static let current = RuntimeProtocolVersion(6)

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
