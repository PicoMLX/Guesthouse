import CryptoKit
import Foundation

/// Everything the runtime service streams back to the GUI.
public enum RuntimeEvent: Codable, Hashable, Sendable {
    /// The reply to `runtimeVersion`.
    case runtimeVersion(RuntimeVersionInfo)
    /// The request was journaled and is now in flight.
    case accepted(OperationID)
    case progress(OperationID, ProgressPhase)
    /// A redacted line of output. Never raw process output.
    case log(OperationID?, RedactedLine)
    case status(EnvironmentStatus)
    case completed(OperationID)
    case failed(OperationID, GuesthouseError)

    public var caseName: String {
        switch self {
        case .runtimeVersion: "runtimeVersion"
        case .accepted: "accepted"
        case .progress: "progress"
        case .log: "log"
        case .status: "status"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

public struct RuntimeVersionInfo: Codable, Hashable, Sendable {
    public var serviceVersion: String
    public var serviceBuild: String
    public var protocolVersion: RuntimeProtocolVersion
    /// `nil` until the service has located a runtime bundle.
    public var tart: TartRuntimeInfo?

    public init(serviceVersion: String, serviceBuild: String, protocolVersion: RuntimeProtocolVersion = .current, tart: TartRuntimeInfo? = nil) {
        self.serviceVersion = serviceVersion
        self.serviceBuild = serviceBuild
        self.protocolVersion = protocolVersion
        self.tart = tart
    }

    public struct TartRuntimeInfo: Codable, Hashable, Sendable {
        /// Parsed from the runtime's own `--version` output: redacted and bounded before it
        /// is stored, so CLI text cannot reach the GUI or diagnostics unchanged.
        public private(set) var version: String
        /// Signature and digest checks passed against the pinned expectations.
        public var verified: Bool

        public init(version: String, verified: Bool) {
            self.version = GuesthouseError.sanitize(version, limit: 64)
            self.verified = verified
        }

        private enum CodingKeys: String, CodingKey { case version, verified }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(version: try c.decode(String.self, forKey: .version), verified: try c.decode(Bool.self, forKey: .verified))
        }
    }
}

/// A named step of an operation, shown as real progress instead of one indefinite spinner
/// (MVP-PLAN.md §2, step 2).
public struct ProgressPhase: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case inspectingState
        case verifyingRuntime
        case startingVM
        case waitingForNetwork
        case stoppingVM
        case forceStoppingVM
        case validatingSelection
        case copying
        case verifyingCopy
    }

    public var kind: Kind
    /// 0...1 when the phase can measure itself; `nil` for indeterminate phases. Only this
    /// type sets it, so a value that cannot be encoded never reaches an event.
    public private(set) var fraction: Double?
    /// False for phases that must not be interrupted (for example a rename after a copy).
    public var cancelable: Bool

    /// A fraction that is not finite or not within `0...1` is dropped, so a backend that
    /// divides by zero yields an indeterminate phase rather than an event that cannot be
    /// encoded.
    public init(kind: Kind, fraction: Double? = nil, cancelable: Bool = true) {
        self.kind = kind
        self.fraction = Self.valid(fraction)
        self.cancelable = cancelable
    }

    private enum CodingKeys: String, CodingKey { case kind, fraction, cancelable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind), fraction: try c.decodeIfPresent(Double.self, forKey: .fraction), cancelable: try c.decodeIfPresent(Bool.self, forKey: .cancelable) ?? true)
    }

    /// A copy of the phase measured at `fraction`, normalized the same way.
    public func measured(_ fraction: Double?) -> ProgressPhase {
        ProgressPhase(kind: kind, fraction: fraction, cancelable: cancelable)
    }

    static func valid(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return fraction
    }
}

/// What the service knows about one environment right now. Produced by reconciling the
/// VM inventory, the process-identity verdict, and the journal; never read from a cache.
public struct EnvironmentStatus: Codable, Hashable, Sendable {
    public enum VMState: Codable, Hashable, Sendable {
        case notFound
        case stopped
        case running
        /// Ownership could not be established (for example a PID that no longer matches).
        /// Start is refused until a person or a repair resolves it.
        case uncertain(reason: String)
    }

    public enum Readiness: Codable, Hashable, Sendable {
        /// Reconciliation has not finished. The GUI shows "Checking environment".
        case checking
        case ready
        case needsAttention(GuesthouseError)
    }

    public var environmentID: EnvironmentID
    public var vm: VMState
    public var readiness: Readiness
    public var inFlightOperation: OperationID?
    /// Versions observed on the host and guest, with unknowns left `nil`.
    /// Only this type sets it, and only through `sanitizedForWire()`: a raw probe value can
    /// never be assigned into a status and encoded unchanged.
    public private(set) var observed: ObservedTuple
    public var reconciledAt: Date?

    public init(
        environmentID: EnvironmentID,
        vm: VMState,
        readiness: Readiness,
        inFlightOperation: OperationID? = nil,
        observed: ObservedTuple = ObservedTuple(),
        reconciledAt: Date? = nil
    ) {
        self.environmentID = environmentID
        self.vm = vm
        self.readiness = readiness
        self.inFlightOperation = inFlightOperation
        // Observations come from guest and CLI probes: every string is bounded and redacted
        // before it crosses XPC, at construction and again when decoded.
        self.observed = observed.sanitizedForWire()
        self.reconciledAt = reconciledAt
    }
}


extension ObservedTuple {
    /// Every string bounded and redacted; capabilities capped in number and length.
    public func sanitizedForWire() -> ObservedTuple {
        func clean(_ value: String?) -> String? { value.map { Self.bounded($0, limit: 256) } }
        var copy = self
        copy.hostMacOSBuild = clean(hostMacOSBuild)
        copy.codexDesktopVersion = clean(codexDesktopVersion)
        copy.codexDesktopBuild = clean(codexDesktopBuild)
        copy.codexDesktopPath = clean(codexDesktopPath)
        copy.tartVersion = clean(tartVersion)
        copy.guestMacOSBuild = clean(guestMacOSBuild)
        copy.xcodeBuild = clean(xcodeBuild)
        copy.codexCLIVersion = clean(codexCLIVersion)
        copy.codexCLIPath = clean(codexCLIPath)
        copy.codexCLICapabilities = codexCLICapabilities.map { Self.boundedCapabilities($0) }
        copy.githubCLIVersion = clean(githubCLIVersion)
        copy.provisioningScriptVersion = clean(provisioningScriptVersion)
        return copy
    }

    /// Sanitizing is lossy, and these values are also an identity: a long path and a
    /// decomposed one can bound to the same text. A value the sanitizer changed therefore
    /// carries a digest of the exact observation, so two different observations never
    /// collapse into one verified compatibility tuple.
    static func bounded(_ value: String, limit: Int) -> String {
        // A value that already contains the identity marker is neutralized first, so untrusted
        // text cannot forge the suffix this function appends and impersonate another value.
        let value = value.replacingOccurrences(of: identityMarker, with: "[exact\u{FFFD}:")
        let (sanitized, wasRedacted) = GuesthouseError.sanitizeReporting(value, limit: limit)
        // A redacted value stands for a secret: it gets no digest, since that would let a
        // guess be confirmed. Whether redaction happened comes from the sanitizer itself, not
        // from marker text the value could contain. Only a value that was merely bounded or
        // normalized carries a digest, counted against the same limit.
        guard sanitized != value, !wasRedacted else { return sanitized }
        let room = max(16, limit - identitySuffixLength)
        return "\(GuesthouseError.sanitize(value, limit: room)) \(identityMarker)\(digest(of: value))]"
    }

    /// `" [exact:" + 12 hex + "]"`, plus the one scalar the sanitizer adds when it truncates.
    static let identitySuffixLength = 22
    static let identityMarker = "[exact:"
    static let maximumCapabilities = 64

    /// The first `maximumCapabilities` entries, each bounded; when entries are dropped, one
    /// final entry names how many and carries a digest of the whole list, so two capability
    /// sets that share a prefix keep different identities.
    static func boundedCapabilities(_ values: [String]) -> [String] {
        guard values.count > maximumCapabilities else { return values.map { bounded($0, limit: 128) } }
        let kept = values.prefix(maximumCapabilities - 1).map { bounded($0, limit: 128) }
        let omitted = values.count - kept.count
        return kept + ["[\(omitted) more; exact:\(digest(ofList: values))]"]
    }

    /// A digest over a length-prefixed encoding, so no two different lists can produce the
    /// same input: a value containing the separator cannot be mistaken for two values.
    static func digest(ofList values: [String]) -> String {
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
