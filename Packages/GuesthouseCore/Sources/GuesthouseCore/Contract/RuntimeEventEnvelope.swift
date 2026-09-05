/// The versioned service-to-GUI event contract for the XPC boundary (MVP-PLAN.md §3).
///
/// Transports must encode and decode this envelope, not a bare `RuntimeEvent`, to reject
/// incompatible service replies before interpreting their version-specific payloads.
public struct RuntimeEventEnvelope: Codable, Hashable, Sendable {
    public var protocolVersion: RuntimeProtocolVersion
    public var event: RuntimeEvent

    public init(protocolVersion: RuntimeProtocolVersion = .current, event: RuntimeEvent) {
        self.protocolVersion = protocolVersion
        self.event = event
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, event }

    /// The outer header is authoritative and required, even for a runtime-version reply.
    /// A foreign header yields `ProtocolMismatch` before the event is decoded. A supported
    /// header with contradictory nested version information is malformed, not a mismatch.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(RuntimeProtocolVersion.self, forKey: .protocolVersion)
        guard version == .current else { throw ProtocolMismatch(service: version) }

        let decodedEvent = try container.decode(RuntimeEvent.self, forKey: .event)
        if case .runtimeVersion(let info) = decodedEvent, info.protocolVersion != version {
            throw DecodingError.dataCorruptedError(
                forKey: .event,
                in: container,
                debugDescription: "The runtime-version payload contradicts its envelope header."
            )
        }
        protocolVersion = version
        event = decodedEvent
    }

    /// Thrown before a foreign service's payload is decoded.
    public struct ProtocolMismatch: Error, Hashable, Sendable {
        public let service: RuntimeProtocolVersion

        public init(service: RuntimeProtocolVersion) {
            self.service = service
        }

        public var error: GuesthouseError {
            .protocolMismatch(client: RuntimeProtocolVersion.current.rawValue, service: service.rawValue)
        }
    }
}
