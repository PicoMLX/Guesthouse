import Foundation

/// Mandatory versioned reply/push envelope. No bare-event or legacy-output fallback.
public struct RuntimeEventEnvelope: Codable, Hashable, Sendable {
    public let protocolVersion: RuntimeProtocolVersion
    public let event: RuntimeEvent

    public init(protocolVersion: RuntimeProtocolVersion = .current, event: RuntimeEvent) {
        self.protocolVersion = protocolVersion
        self.event = event
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, event }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(RuntimeProtocolVersion.self, forKey: .protocolVersion)
        guard version == .current else { throw ProtocolMismatch(service: version) }
        let decoded = try c.decode(RuntimeEvent.self, forKey: .event)
        if case .runtimeVersion(let info) = decoded, info.protocolVersion != version {
            throw GuesthouseError.invalidRuntimeReply(.malformed)
        }
        if case .hostPreflight(let report) = decoded, !report.isComplete {
            throw GuesthouseError.invalidRuntimeReply(.malformed)
        }
        protocolVersion = version
        event = decoded
    }

    public struct ProtocolMismatch: Error, Hashable, Sendable {
        public let service: RuntimeProtocolVersion
        public init(service: RuntimeProtocolVersion) { self.service = service }
        public var error: GuesthouseError {
            .protocolMismatch(client: RuntimeProtocolVersion.current.rawValue, service: service.rawValue)
        }
    }

    public static let maximumEncodedSize = 64 * 1024

    /// Transport entry point: enforce bytes before parsing, then version before event shape.
    /// Any rejection leaves in-flight mutation outcomes unknown until the owner reconciles them.
    public static func decode(_ data: Data) throws(GuesthouseError) -> Self {
        guard data.count <= maximumEncodedSize else { throw .invalidRuntimeReply(.oversized) }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch let error as ProtocolMismatch {
            throw error.error
        } catch {
            // Never export decoder descriptions, coding paths or private payload fragments.
            throw .invalidRuntimeReply(.malformed)
        }
    }

    /// Use for native replies and pushes. No contradictory/oversized envelope leaves this path.
    public func encoded() throws(GuesthouseError) -> Data {
        guard protocolVersion == .current else {
            throw ProtocolMismatch(service: protocolVersion).error
        }
        if case .runtimeVersion(let info) = event, info.protocolVersion != protocolVersion {
            throw .invalidRuntimeReply(.malformed)
        }
        if case .hostPreflight(let report) = event, !report.isComplete {
            throw .invalidRuntimeReply(.malformed)
        }
        do {
            let data = try JSONEncoder().encode(self)
            guard data.count <= Self.maximumEncodedSize else { throw GuesthouseError.invalidRuntimeReply(.oversized) }
            return data
        } catch let error as GuesthouseError {
            throw error
        } catch {
            throw .invalidRuntimeReply(.malformed)
        }
    }
}
