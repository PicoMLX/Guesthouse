/// Version of the message contract between the GUI and the GuesthouseRuntime XPC service.
///
/// Bump on any change a peer from the previous version could misread. Both sides send it in
/// every envelope, and the service refuses a mismatch with `GuesthouseError.protocolMismatch`.
public struct RuntimeProtocolVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    /// History: 1 was the initial contract; 2 added `InvalidRequestReason.tooManyInFlight`;
    /// 3 made `TartRuntimeInfo.version` optional, added its `problem`, and added the storage
    /// error, so an older peer would fail to decode a reply instead of being told what
    /// happened, and would read `verified` with the wrong meaning; 4 added the
    /// `listEnvironments` request, the `environments` event, `EnvironmentStatus.guestAddress`,
    /// and the lifecycle's own error cases, none of which a version-3 peer can decode; 5 added
    /// the `xcodeCandidate` reply, which a version-4 peer cannot decode and would report as a
    /// dropped connection rather than as a version it can act on.
    public static let current = RuntimeProtocolVersion(5)

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
