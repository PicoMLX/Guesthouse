import Foundation

/// Live observations, not saved provisioning completion (MVP-PLAN.md §5, issue #187).
public enum EnvironmentCapability: String, CaseIterable, Hashable, Sendable {
    case connection, buildTools, credentials, desktop, guiAutomation
}

public enum CapabilityState: Equatable, Sendable {
    case unknown, checking, ready
    case unavailable(CapabilityReason)
    case needsUserAction(CapabilityReason)
}

/// Fixed presentation facts, never process output, paths or permission transcripts.
public enum CapabilityReason: String, CaseIterable, Sendable {
    case disconnected, toolUnavailable, permissionRequired, sessionLocked, inspectionFailed

    public var userMessage: String {
        switch self {
        case .disconnected: "Reconnect to the development Mac and check again."
        case .toolUnavailable: "The required tool is unavailable. Check its installation."
        case .permissionRequired: "Review the required permission in System Settings, then check again."
        case .sessionLocked: "Unlock the guest session, then check again."
        case .inspectionFailed: "Guesthouse could not verify this capability. Inspect its state before continuing."
        }
    }
}

/// Private operational identity, not a diagnostic payload or proof of provider acceptance.
/// The producer must rotate instanceID when the relevant executable/helper is replaced,
/// even when its reported version and path stay unchanged. No filesystem inspection here.
public struct CapabilityToolIdentity: Equatable, Sendable {
    public let tuple: CompatibilityTuple
    public let instanceID: UUID

    public init(tuple: CompatibilityTuple, instanceID: UUID) throws(CompatibilityRecordError) {
        try ConnectionVerificationRecord.validate(tuple)
        self.tuple = tuple
        self.instanceID = instanceID
    }
}

/// Only the ledger admits requests. Neither requests nor the ledger are Codable: restored
/// status/connection history must start a new live ledger and new observations.
public struct CapabilityObservationRequest: Sendable {
    public let environmentID: EnvironmentID
    public let capability: EnvironmentCapability
    public let tool: CapabilityToolIdentity
    fileprivate let context: UUID
    fileprivate let revision: UUID
    fileprivate let requestID: UUID
}

public enum CapabilityInvalidation: CaseIterable, Sendable {
    case coldBoot, reconnect, wake, lock, unlock, permissionChange

    fileprivate var affected: [EnvironmentCapability] {
        switch self {
        case .coldBoot, .reconnect, .wake: EnvironmentCapability.allCases
        case .lock, .unlock: [.credentials, .desktop, .guiAutomation]
        case .permissionChange: [.guiAutomation]
        }
    }
}

/// Pure, bounded observation ledger: at most five entries and one request per capability.
/// One owner serializes these value transitions; this is not a runtime admission lock.
/// Call invalidation on lifecycle/permission changes and replace the tool on identity drift.
/// No timestamps can revive a revoked request. A fresh UUID revision avoids counter wrap.
/// Existing EnvironmentStatus wire/schema layouts are UNCHANGED; absent live evidence is
/// unknown. A future wire representation requires explicit protocol/schema review, not
/// Codable conformance that restores ready observations from disk.
public struct EnvironmentCapabilities: Sendable {
    private struct Entry: Sendable {
        let tool: CapabilityToolIdentity
        var revision = UUID()
        var pending: UUID?
        var state: CapabilityState = .unknown
    }

    public let environmentID: EnvironmentID
    private var generation: RuntimeSessionGeneration
    private var context = UUID()
    private var entries: [EnvironmentCapability: Entry] = [:]

    public init(environmentID: EnvironmentID, generation: RuntimeSessionGeneration) {
        self.environmentID = environmentID
        self.generation = generation
    }

    /// A replacement always revokes the old context, even if the same generation is supplied.
    /// Guest reconnects within a still-live host XPC session must also call this or invalidate.
    public mutating func reconnect(generation: RuntimeSessionGeneration) {
        self.generation = generation
        context = UUID()
        invalidate(.reconnect)
    }

    /// A changed identity invalidates just the capability it supports. The producer calls
    /// this for every affected capability when a shared tool is replaced.
    public mutating func setTool(_ tool: CapabilityToolIdentity, for capability: EnvironmentCapability) {
        guard entries[capability]?.tool != tool else { return }
        entries[capability] = Entry(tool: tool)
    }

    public mutating func invalidate(_ event: CapabilityInvalidation) {
        for capability in event.affected {
            guard var entry = entries[capability] else { continue }
            entry.revision = UUID()
            entry.pending = nil
            entry.state = .unknown
            entries[capability] = entry
        }
    }

    public func state(of capability: EnvironmentCapability) -> CapabilityState {
        guard generation.retirementFailure == nil else { return .unknown }
        return entries[capability]?.state ?? .unknown
    }

    public mutating func begin(_ capability: EnvironmentCapability) -> CapabilityObservationRequest? {
        guard generation.retirementFailure == nil, var entry = entries[capability] else { return nil }
        let requestID = UUID()
        entry.pending = requestID
        entry.state = .checking
        entries[capability] = entry
        return CapabilityObservationRequest(environmentID: environmentID, capability: capability,
                                            tool: entry.tool, context: context,
                                            revision: entry.revision, requestID: requestID)
    }

    /// The adapter supplies the actual result's environment, generation and tool identity,
    /// not values copied from an unrelated request. This compares provenance; it cannot
    /// prove a probe or permission grant happened. A result is terminal and consumes its request.
    @discardableResult
    public mutating func complete(_ request: CapabilityObservationRequest,
                                  environmentID: EnvironmentID, generation: RuntimeSessionGeneration,
                                  tool: CapabilityToolIdentity, result: CapabilityState) -> Bool {
        guard self.environmentID == environmentID, request.environmentID == environmentID,
              self.generation === generation, generation.retirementFailure == nil,
              request.context == context, request.tool == tool,
              var entry = entries[request.capability], entry.tool == tool,
              entry.revision == request.revision, entry.pending == request.requestID else { return false }
        // Unknown/checking are transitions, not terminal probe results.
        switch result {
        case .unknown, .checking: return false
        case .ready, .unavailable, .needsUserAction: break
        }
        entry.pending = nil
        entry.state = result
        entries[request.capability] = entry
        return true
    }
}

public enum CapabilityWorkflow: CaseIterable, Sendable {
    case shell, build, authenticatedTools, desktop, guiAutomation

    fileprivate var required: [EnvironmentCapability] {
        switch self {
        case .shell: [.connection]
        case .build: [.connection, .buildTools]
        case .authenticatedTools: [.connection, .credentials]
        case .desktop: [.connection, .desktop]
        case .guiAutomation: [.connection, .desktop, .guiAutomation]
        }
    }
}

public enum CapabilityAvailability: Equatable, Sendable {
    case available
    case requiresInspection
    case blocked([EnvironmentCapability])
}

extension EnvironmentStatus {
    /// Capability-specific presentation only, NEVER mutation authorization, compatibility
    /// approval or a hardware gate. Existing ownership, current tuple compatibility, journal
    /// reconciliation and per-action runtime admission remain separate mandatory checks.
    public func capabilityAvailability(for workflow: CapabilityWorkflow,
                                       using capabilities: EnvironmentCapabilities) -> CapabilityAvailability {
        guard environmentID == capabilities.environmentID, vm == .running,
              inFlightOperation == nil, readiness == .ready else { return .requiresInspection }
        let missing = workflow.required.filter { capabilities.state(of: $0) != .ready }
        return missing.isEmpty ? .available : .blocked(missing)
    }
}
