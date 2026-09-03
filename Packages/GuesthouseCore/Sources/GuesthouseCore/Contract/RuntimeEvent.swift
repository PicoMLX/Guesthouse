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
        public var version: String
        /// Signature and digest checks passed against the pinned expectations.
        public var verified: Bool

        public init(version: String, verified: Bool) {
            self.version = version
            self.verified = verified
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
    /// 0...1 when the phase can measure itself; `nil` for indeterminate phases.
    public var fraction: Double?
    /// False for phases that must not be interrupted (for example a rename after a copy).
    public var cancelable: Bool

    public init(kind: Kind, fraction: Double? = nil, cancelable: Bool = true) {
        self.kind = kind
        self.fraction = fraction
        self.cancelable = cancelable
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
    public var observed: ObservedTuple
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
        self.observed = observed
        self.reconciledAt = reconciledAt
    }
}
