import Foundation

/// Everything the GUI may ask the runtime service to do.
///
/// Requests name environments and operations and carry validated options. They never carry a
/// path to execute, an executable, or a Tart flag: the service chooses those itself
/// (MVP-PLAN.md §3, "Sandbox and XPC boundary").
public enum RuntimeRequest: Codable, Hashable, Sendable {
    case runtimeVersion
    case environmentStatus(EnvironmentID)
    case startEnvironment(EnvironmentID, StartOptions)
    case stopEnvironment(EnvironmentID, StopMode)
    case importXcode(EnvironmentID, FileHandoff)
    case cancelOperation(OperationID)

    public var caseName: String {
        switch self {
        case .runtimeVersion: "runtimeVersion"
        case .environmentStatus: "environmentStatus"
        case .startEnvironment: "startEnvironment"
        case .stopEnvironment: "stopEnvironment"
        case .importXcode: "importXcode"
        case .cancelOperation: "cancelOperation"
        }
    }

    /// Whether the service changes host state for this request.
    ///
    /// A request that is interrupted before it is accepted carries no operation id, but it may
    /// still have reached the service and been journaled or started. A mutating one therefore
    /// has an unknown outcome and is never offered a blind retry; a read-only query changed
    /// nothing and may simply be asked again. Cancelling counts as read-only because asking
    /// twice cannot leave the host anywhere asking once would not.
    public var mutatesHost: Bool {
        switch self {
        case .runtimeVersion, .environmentStatus, .cancelOperation: false
        case .startEnvironment, .stopEnvironment, .importXcode: true
        }
    }
}

/// Every message from the GUI carries the protocol version it speaks.
public struct RuntimeRequestEnvelope: Codable, Hashable, Sendable {
    public var protocolVersion: RuntimeProtocolVersion
    public var request: RuntimeRequest

    public init(protocolVersion: RuntimeProtocolVersion = .current, request: RuntimeRequest) {
        self.protocolVersion = protocolVersion
        self.request = request
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, request }

    /// The version header is read first; a peer on another protocol is reported as
    /// `ProtocolMismatch` before its version-specific payload is decoded, so a request case
    /// this build does not know yields the actionable mismatch, never a malformed request.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(RuntimeProtocolVersion.self, forKey: .protocolVersion)
        guard version == .current else { throw ProtocolMismatch(client: version) }
        protocolVersion = version
        request = try container.decode(RuntimeRequest.self, forKey: .request)
    }

    /// Thrown by `init(from:)` before the payload is decoded.
    public struct ProtocolMismatch: Error, Hashable, Sendable {
        public let client: RuntimeProtocolVersion
        public var error: GuesthouseError { .protocolMismatch(client: client.rawValue, service: RuntimeProtocolVersion.current.rawValue) }
    }

    /// The version header on its own. Decoding this reads one integer and never looks at the
    /// request, so a peer that is being refused before its payload is decoded can still be
    /// answered with an error its own protocol version knows how to read.
    public struct Header: Decodable, Hashable, Sendable {
        public let protocolVersion: RuntimeProtocolVersion

        public init(protocolVersion: RuntimeProtocolVersion) {
            self.protocolVersion = protocolVersion
        }
    }
}

public struct StartOptions: Codable, Hashable, Sendable {
    /// Which console the VM gets. The service maps this to its own Tart arguments.
    public enum ConsoleMode: String, Codable, Hashable, Sendable {
        /// Normal daily operation; the guest is reached over SSH and Screen Sharing.
        case headless
        /// Tart's native window, for first boot and recovery only (MVP-PLAN.md §4).
        case native
    }

    public var console: ConsoleMode
    /// How long the service may wait for the guest to obtain an IP address before reporting
    /// `guestNotReachable`. Bounded by `RequestValidator.maximumIPWait`.
    public var ipWait: Duration

    public init(console: ConsoleMode = .headless, ipWait: Duration = .seconds(90)) {
        self.console = console
        self.ipWait = ipWait
    }
}

public enum StopMode: Codable, Hashable, Sendable {
    /// Ask the guest to shut down and wait up to `deadline`.
    case graceful(deadline: Duration)
    /// Kill the VM process. Only after the GUI has shown the explicit force-stop warning
    /// (MVP-PLAN.md §2).
    case force
}

/// A user-selected file or bundle handed from the sandboxed GUI to the service.
///
/// The authority to read is the bookmark or the out-of-band file descriptor, never the
/// display name (MVP-PLAN.md §3: "A path string alone is not a transferable sandbox
/// permission"). The service re-validates what it receives; the caller's claims are hints.
public struct FileHandoff: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// A security-scoped bookmark created by the GUI from an `NSOpenPanel` selection.
        case securityScopedBookmark(Data)
        /// A descriptor sent alongside the message, identified by this token.
        case fileDescriptor(token: UUID)
    }

    public var kind: Kind
    /// Shown in progress and errors, for example `Xcode.app`. Not used to open anything.
    public var displayName: String
    /// What the GUI believes it selected; the service verifies the bundle itself.
    public var expectedBundleIdentifier: String?

    public init(kind: Kind, displayName: String, expectedBundleIdentifier: String? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }
}
