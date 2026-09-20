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
    case disconnected, toolUnavailable, permissionRequired, sessionLocked, inspectionFailed, signInRequired

    public var userMessage: String {
        switch self {
        case .disconnected: "Reconnect to the development Mac and check again."
        case .toolUnavailable: "The required tool is unavailable. Check its installation."
        case .permissionRequired: "Review the required permission in System Settings, then check again."
        case .sessionLocked: "Unlock the guest session, then check again."
        case .inspectionFailed: "Guesthouse could not verify this capability. Inspect its state before continuing."
        case .signInRequired: "Sign in again to the intended account inside the development Mac, then check again."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .signInRequired: [.signInAgain, .cancel]
        case .permissionRequired: [.openSettings, .cancel]
        case .sessionLocked: [.openConsole, .cancel]
        case .toolUnavailable: [.repair(.tools), .cancel]
        case .disconnected, .inspectionFailed: [.inspectState, .cancel]
        }
    }
}

/// Private operational identity, not a diagnostic payload or proof of provider acceptance.
/// instanceID identifies the producer-selected probe/target configuration, including an
/// absent target. Rotate it on replacement or absent/present transition, even when reported
/// versions stay unchanged. The optional complete tuple is validated compatibility metadata,
/// not a prerequisite for reporting unavailable tools. No filesystem inspection here.
public struct CapabilityToolIdentity: Equatable, Sendable {
    public let tuple: CompatibilityTuple?
    public let instanceID: UUID

    public init(tuple: CompatibilityTuple? = nil, instanceID: UUID) throws(CompatibilityRecordError) {
        if let tuple { try ConnectionVerificationRecord.validate(tuple) }
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
/// Actor reference identity means aliases share revocation; copying cannot fork authority.
/// No transition suspends internally. This is not a runtime mutation admission lock.
/// Call invalidation on lifecycle/permission changes and replace the tool on identity drift.
/// No timestamps can revive a revoked request. A fresh UUID revision avoids counter wrap.
/// Existing EnvironmentStatus wire/schema layouts are UNCHANGED; absent live evidence is
/// unknown. A future wire representation requires explicit protocol/schema review, not
/// Codable conformance that restores ready observations from disk.
public actor EnvironmentCapabilities {
    private struct Entry: Sendable {
        let tool: CapabilityToolIdentity
        var revision = UUID()
        var pending: UUID?
        var state: CapabilityState = .unknown
    }

    public let environmentID: EnvironmentID
    private let currentGeneration: @Sendable () -> RuntimeSessionGeneration?
    private var generation: RuntimeSessionGeneration?
    private var context = UUID()
    private var entries: [EnvironmentCapability: Entry] = [:]

    public init<Session: Sendable>(environmentID: EnvironmentID, registry: RuntimeSessionRegistry<Session>) {
        self.environmentID = environmentID
        currentGeneration = { registry.current?.generation }
        generation = registry.current?.generation
    }

    private var isCurrent: Bool {
        guard let generation else { return false }
        return currentGeneration() === generation
    }

    /// A replacement always revokes the old context, even if the same generation remains active.
    /// Guest reconnects within a still-live host XPC session must also call this or invalidate.
    public func reconnect() {
        generation = currentGeneration()
        context = UUID()
        invalidate(.reconnect)
    }

    /// A changed identity invalidates just the capability it supports. The producer calls
    /// this for every affected capability when a shared tool is replaced.
    public func setTool(_ tool: CapabilityToolIdentity, for capability: EnvironmentCapability) {
        guard entries[capability]?.tool != tool else { return }
        entries[capability] = Entry(tool: tool)
    }

    public func invalidate(_ event: CapabilityInvalidation) {
        for capability in event.affected {
            guard var entry = entries[capability] else { continue }
            entry.revision = UUID()
            entry.pending = nil
            entry.state = .unknown
            entries[capability] = entry
        }
    }

    public func state(of capability: EnvironmentCapability) -> CapabilityState {
        guard isCurrent else { return .unknown }
        return entries[capability]?.state ?? .unknown
    }

    public func begin(_ capability: EnvironmentCapability) -> CapabilityObservationRequest? {
        guard isCurrent, var entry = entries[capability] else { return nil }
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
    public func complete(_ request: CapabilityObservationRequest,
                                  environmentID: EnvironmentID, generation: RuntimeSessionGeneration,
                                  tool: CapabilityToolIdentity, result: CapabilityState) -> Bool {
        guard self.environmentID == environmentID, request.environmentID == environmentID,
              self.generation === generation, isCurrent,
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

    /// One actor turn evaluates all required observations against the current activated lease.
    fileprivate func availability(for workflow: CapabilityWorkflow, status: EnvironmentStatus) -> CapabilityAvailability {
        guard environmentID == status.environmentID, status.vm == .running,
              status.inFlightOperation == nil, status.readiness == .ready else { return .requiresInspection }
        guard isCurrent else { return .blocked(workflow.required) }
        let missing = workflow.required.filter { entries[$0]?.state != .ready }
        return missing.isEmpty ? .available : .blocked(missing)
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
                                       using capabilities: EnvironmentCapabilities) async -> CapabilityAvailability {
        await capabilities.availability(for: workflow, status: self)
    }
}
