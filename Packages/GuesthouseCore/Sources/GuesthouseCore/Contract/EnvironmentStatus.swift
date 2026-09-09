import Foundation

/// Private status, not diagnostics. The producer must reconcile inventory/ownership/journal;
/// constructing or decoding this value does not prove reconciliation or authorize mutation.
public struct EnvironmentStatus: Codable, Hashable, Sendable {
    public enum VMState: Codable, Hashable, Sendable {
        case notFound, stopped, running
        /// Refuse mutation until ownership/state is inspected. No raw process reason text.
        case uncertain(reason: UncertaintyReason)
    }
    public enum UncertaintyReason: String, Codable, Hashable, Sendable, CaseIterable {
        case ownershipUnproven, processIdentityChanged, inspectionFailed, operationOutcomeUnknown

        public var userMessage: String {
            switch self {
            case .ownershipUnproven: "Guesthouse could not confirm ownership of this development Mac."
            case .processIdentityChanged: "The development Mac's process identity changed."
            case .inspectionFailed: "Guesthouse could not inspect the development Mac's current state."
            case .operationOutcomeUnknown: "The previous operation's outcome is not yet known."
            }
        }
        public var recoveryActions: [RecoveryAction] { [.inspectState, .cancel] }
    }
    public enum Readiness: Codable, Hashable, Sendable {
        case checking, ready
        case needsAttention(GuesthouseError)
    }

    public let environmentID: EnvironmentID
    public let vm: VMState
    /// Separate from ownership and compatibility. `ready` alone is not a handoff gate.
    public let readiness: Readiness
    public let inFlightOperation: OperationID?
    public let observed: ObservedTuple
    public let reconciledAt: Date?

    public init(environmentID: EnvironmentID, vm: VMState, readiness: Readiness,
                inFlightOperation: OperationID? = nil, observed: ObservedTuple = ObservedTuple(),
                reconciledAt: Date? = nil) {
        self.environmentID = environmentID
        self.vm = vm
        self.readiness = readiness
        self.inFlightOperation = inFlightOperation
        self.observed = observed.admittedForWire()
        self.reconciledAt = reconciledAt
    }

    private enum CodingKeys: String, CodingKey {
        case environmentID, vm, readiness, inFlightOperation, observed, reconciledAt
    }

    /// Apply the same field admission to untrusted wire values as to local probe results.
    /// Underlying decoding errors stay private; the event transport must map them to fixed errors.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(environmentID: try c.decode(EnvironmentID.self, forKey: .environmentID),
                  vm: try c.decode(VMState.self, forKey: .vm),
                  readiness: try c.decode(Readiness.self, forKey: .readiness),
                  inFlightOperation: try c.decodeIfPresent(OperationID.self, forKey: .inFlightOperation),
                  observed: try c.decode(ObservedTuple.self, forKey: .observed),
                  reconciledAt: try c.decodeIfPresent(Date.self, forKey: .reconciledAt))
    }
}
