import Foundation

/// Named requests from #9 / MVP-PLAN.md §3. The service chooses executables and arguments;
/// private selection metadata is not a command, a diagnostic attachment, or access authority.
public enum RuntimeRequest: Codable, Hashable, Sendable {
    case runtimeVersion
    /// Read-only report; policy and storage identity are selected and retained by the service.
    case hostPreflight
    case environmentStatus(EnvironmentID)
    case startEnvironment(EnvironmentID, StartOptions)
    case stopEnvironment(EnvironmentID, StopMode)
    case importXcode(EnvironmentID, FileHandoff)
    case cancelOperation(OperationID)

    public var caseName: String {
        switch self {
        case .runtimeVersion: "runtimeVersion"
        case .hostPreflight: "hostPreflight"
        case .environmentStatus: "environmentStatus"
        case .startEnvironment: "startEnvironment"
        case .stopEnvironment: "stopEnvironment"
        case .importXcode: "importXcode"
        case .cancelOperation: "cancelOperation"
        }
    }
}

/// Decode untrusted bytes through RequestValidator.decode, which bounds input first.
/// Codable alone checks the version, not the transport's complete admission policy.
public struct RuntimeRequestEnvelope: Codable, Hashable, Sendable {
    public let protocolVersion: RuntimeProtocolVersion
    public let request: RuntimeRequest

    public init(protocolVersion: RuntimeProtocolVersion = .current, request: RuntimeRequest) {
        self.protocolVersion = protocolVersion
        self.request = request
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, request }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(RuntimeProtocolVersion.self, forKey: .protocolVersion)
        guard version == .current else { throw ProtocolMismatch(client: version) }
        protocolVersion = version
        request = try container.decode(RuntimeRequest.self, forKey: .request)
    }

    /// A foreign header takes precedence over an unknown or absent payload.
    public struct ProtocolMismatch: Error, Hashable, Sendable {
        public let client: RuntimeProtocolVersion
        public var error: GuesthouseError {
            .protocolMismatch(client: client.rawValue, service: RuntimeProtocolVersion.current.rawValue)
        }
    }
}

public struct StartOptions: Codable, Hashable, Sendable {
    /// Capability requests, not provider flags. The runtime must reject unsupported modes.
    public enum ConsoleMode: String, Codable, Hashable, Sendable {
        case headless, native
    }
    public let console: ConsoleMode
    public let ipWait: Duration

    public init(console: ConsoleMode = .headless, ipWait: Duration = .seconds(90)) {
        self.console = console
        self.ipWait = ipWait
    }
}

public enum StopMode: Codable, Hashable, Sendable {
    case graceful(deadline: Duration)
    /// The GUI must obtain explicit confirmation; this value does not prove it did so.
    case force
}

/// Access travels through a bookmark or an authenticated out-of-band descriptor handoff.
/// Runtime selection/signature/containment checks remain required; hints never authorize it.
public struct FileHandoff: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case securityScopedBookmark(Data)
        case fileDescriptor(token: UUID)
    }
    public let kind: Kind
    /// Private selection UI only. Never interpolate into error messages, logs or exports.
    public let displayName: String
    /// Bounded private hint. The service must independently verify the actual Xcode bundle.
    public let expectedBundleIdentifier: String?

    public init(kind: Kind, displayName: String, expectedBundleIdentifier: String? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }
}
