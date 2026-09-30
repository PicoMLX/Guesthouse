import Foundation
import GuesthouseCore

/// Shared status projection for #24 (MVP §§3–4). Call on the bounded read-only worker.
/// No process is adopted/signaled and no journal operation is settled by a status request.
struct RuntimeEnvironmentInspector: Sendable {
    struct Evidence: Sendable {
        var processes: [LiveProcess]
        var complete: Bool
        var lockPresent: Bool?
        static let unavailable = Evidence(processes: [], complete: false, lockPresent: nil)
    }

    // Runtime-only provider seam. Until a provider is accepted, neither its inventory nor
    // lock semantics can be claimed. A known-PID probe alone cannot make this complete.
    var inspect: @Sendable (ProcessIdentity) -> Evidence = { _ in .unavailable }

    func status(for id: EnvironmentID, snapshot: EnvironmentsSnapshot, journal: JournalReplay,
                metadataUsable: Bool, now: Date = Date()) -> EnvironmentStatus {
        // An interrupted operation overrides even exact process evidence: a running process
        // cannot establish the outcome of an import, stop, deletion or other prior mutation.
        if let pending = journal.inFlight.values.first(where: { $0.environmentID == id }) {
            return EnvironmentStatus(environmentID: id, vm: .uncertain(reason: .operationOutcomeUnknown),
                readiness: .needsAttention(.operationOutcomeUnknown(pending.id)), inFlightOperation: pending.id)
        }
        guard metadataUsable, !journal.truncatedTail,
              snapshot.environments.contains(where: { $0.id == id }) else { return Self.unavailable(id) }
        guard let identity = snapshot.processIdentities[id] else {
            return EnvironmentStatus(environmentID: id, vm: .uncertain(reason: .ownershipUnproven), readiness: .checking)
        }
        let evidence = inspect(identity)
        let verdict = ProcessReconciler.reconcile(recorded: identity, observed: evidence.processes,
            observationComplete: evidence.complete, vmLockPresent: evidence.lockPresent)
        let vm: EnvironmentStatus.VMState
        switch verdict {
        case .ownedRunning: vm = .running
        case .exited: vm = .stopped
        case .uncertain(let reason):
            let statusReason: EnvironmentStatus.UncertaintyReason
            switch reason {
            case .pidReusedByAnotherProcess, .executableMismatch, .argumentsMismatch: statusReason = .processIdentityChanged
            case .processUnobservable, .inventoryUnavailable: statusReason = .inspectionFailed
            default: statusReason = .ownershipUnproven
            }
            return EnvironmentStatus(environmentID: id, vm: .uncertain(reason: statusReason), readiness: .checking)
        }
        // Process evidence never supplies guest/tool readiness or capability success.
        return EnvironmentStatus(environmentID: id, vm: vm, readiness: .checking, reconciledAt: now)
    }

    static func unavailable(_ id: EnvironmentID) -> EnvironmentStatus {
        EnvironmentStatus(environmentID: id, vm: .uncertain(reason: .inspectionFailed), readiness: .checking)
    }
}
