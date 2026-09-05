import Foundation
import GuesthouseCore

/// Runtime-root ownership, not a PID. Epoch and generation prevent another service instance
/// or a later lease from consuming stale evidence (MVP-PLAN.md §3 and §4).
struct LumeOwnershipIdentity: Codable, Hashable, Sendable {
    let rootDevice: Int64
    let rootInode: UInt64
    let operationID: UUID
    let serviceEpoch: UUID
    let generation: UUID
}

enum LumeOwnershipFailure: Error, Hashable, Sendable, LocalizedError {
    case staleOwner, staleInspection, invalidTransition, invalidRecord, unsupportedFormat
    case tooManyAttempts, revisionExhausted

    var userMessage: String {
        "Guesthouse cannot establish that this runtime operation has released its ownership. Preserve its storage and inspect the actual state before another operation."
    }
    var recoveryActions: [RecoveryAction] { [.inspectState, .cancel] }
    var errorDescription: String? { userMessage }
}

enum LumeQuarantineReason: String, Codable, CaseIterable, Sendable {
    case terminationRefused, interrupted, unprovenCleanup, ownershipLost, persistenceFailure, restarted
}

/// Observations that never establish whole-owned-set quiescence. In particular, the proposed
/// owned launcher can observe/reap its leader without proving escaped descendants are gone.
enum LumeCleanupObservation: CaseIterable, Sendable {
    case leaderExited, signalDelivered, timedOut, canceled, terminationRefused, ownershipLost

    var reason: LumeQuarantineReason {
        switch self {
        case .leaderExited, .signalDelivered: .unprovenCleanup
        case .timedOut, .canceled: .interrupted
        case .terminationRefused: .terminationRefused
        case .ownershipLost: .ownershipLost
        }
    }
}

/// Input contract for a future trusted inspector, NOT an implementation of inspection.
/// No production issuer or runner adapter exists. Never construct this from ProcessExit,
/// PID absence, signal delivery, a lock becoming available, or a GUI-supplied Boolean.
/// Stage-one tests supply synthetic inspection results solely to exercise transition checks.
struct LumeOwnedSetInspection: Sendable {
    enum Conclusion: Equatable, Sendable { case unresolved, entireOwnedSetQuiescent }
    let identity: LumeOwnershipIdentity
    let revision: UInt64
    let attemptIDs: Set<UUID>
    let conclusion: Conclusion
}

/// Pure, internal transition model; it performs no I/O and authorizes no actual launch.
/// The future ledger must durably publish a returned value before any corresponding effect,
/// and the coordinator must hold/revalidate the same guard across that publication.
struct LumeOwnershipRecord: Codable, Hashable, Sendable {
    static let currentFormat = 1
    static let maximumAttempts = 64

    enum Phase: Codable, Hashable, Sendable {
        case reserved, executing, quarantined(LumeQuarantineReason)
        /// Ownership is clear, not proof that the business operation succeeded or is retryable.
        case settled
    }

    let identity: LumeOwnershipIdentity
    let revision: UInt64
    let phase: Phase
    let attemptIDs: Set<UUID>
    let pendingAttempts: Set<UUID>

    init(reserving identity: LumeOwnershipIdentity) {
        self.identity = identity
        revision = 0
        phase = .reserved
        attemptIDs = []
        pendingAttempts = []
    }

    /// Persist BEFORE entering the launcher, including before awaiting spawn. A crash before
    /// the returned child identity is attached still leaves this attempt unresolved.
    func registeringLaunch(_ attemptID: UUID, owner: LumeOwnershipIdentity) throws -> Self {
        try requireOwner(owner)
        guard phase == .reserved, !attemptIDs.contains(attemptID) else {
            throw LumeOwnershipFailure.invalidTransition
        }
        guard attemptIDs.count < Self.maximumAttempts else { throw LumeOwnershipFailure.tooManyAttempts }
        var attempts = attemptIDs
        attempts.insert(attemptID)
        return try changing(to: .executing, attempts: attempts, pending: [attemptID])
    }

    func recording(_ observation: LumeCleanupObservation, owner: LumeOwnershipIdentity) throws -> Self {
        try quarantining(observation.reason, owner: owner)
    }

    func quarantining(_ reason: LumeQuarantineReason, owner: LumeOwnershipIdentity) throws -> Self {
        try requireOwner(owner)
        guard phase != .settled else { throw LumeOwnershipFailure.invalidTransition }
        return try changing(to: .quarantined(reason))
    }

    /// Every unfinished reservation is orphaned after restart, even before a recorded spawn.
    /// Changing the revision invalidates an inspection captured before the restart boundary.
    func recoveringAfterRestart() throws -> Self {
        guard phase != .settled else { return self }
        return try changing(to: .quarantined(.restarted))
    }

    /// A no-pending-run path can settle only while the live operation still owns its lease.
    /// Quarantine cannot be cleared by throwing, cancellation, or returning from the closure.
    func finishing(owner: LumeOwnershipIdentity) throws -> Self {
        try requireOwner(owner)
        guard phase == .reserved, pendingAttempts.isEmpty else {
            throw LumeOwnershipFailure.invalidTransition
        }
        return try changing(to: .settled)
    }

    func accepting(_ inspection: LumeOwnedSetInspection) throws -> Self {
        try requireOwner(inspection.identity)
        guard inspection.revision == revision, inspection.attemptIDs == attemptIDs else {
            throw LumeOwnershipFailure.staleInspection
        }
        switch phase {
        case .reserved, .settled: throw LumeOwnershipFailure.invalidTransition
        case .executing, .quarantined: break
        }
        guard inspection.conclusion == .entireOwnedSetQuiescent else {
            return try changing(to: .quarantined(.unprovenCleanup))
        }
        // An interrupted operation never resumes mid-operation. Verified inspection settles
        // its ownership; admission of a separate new operation is a later durable transaction.
        let next: Phase = phase == .executing ? .reserved : .settled
        return try changing(to: next, pending: [])
    }

    private func requireOwner(_ candidate: LumeOwnershipIdentity) throws {
        guard candidate == identity else { throw LumeOwnershipFailure.staleOwner }
    }

    private func changing(to phase: Phase, attempts: Set<UUID>? = nil, pending: Set<UUID>? = nil) throws -> Self {
        guard revision < UInt64.max else { throw LumeOwnershipFailure.revisionExhausted }
        return try Self(Wire(format: Self.currentFormat, identity: identity, revision: revision + 1,
                             phase: phase, attemptIDs: attempts ?? attemptIDs,
                             pendingAttempts: pending ?? pendingAttempts))
    }

    private struct Wire: Codable {
        let format: Int
        let identity: LumeOwnershipIdentity
        let revision: UInt64
        let phase: Phase
        let attemptIDs: Set<UUID>
        let pendingAttempts: Set<UUID>
    }

    private init(_ wire: Wire) throws {
        guard wire.format == Self.currentFormat else { throw LumeOwnershipFailure.unsupportedFormat }
        guard wire.attemptIDs.count <= Self.maximumAttempts,
              wire.pendingAttempts.isSubset(of: wire.attemptIDs) else {
            throw LumeOwnershipFailure.invalidRecord
        }
        switch wire.phase {
        case .reserved, .settled:
            guard wire.pendingAttempts.isEmpty else { throw LumeOwnershipFailure.invalidRecord }
        case .executing:
            guard wire.pendingAttempts.count == 1 else { throw LumeOwnershipFailure.invalidRecord }
        case .quarantined: break
        }
        identity = wire.identity
        revision = wire.revision
        phase = wire.phase
        attemptIDs = wire.attemptIDs
        pendingAttempts = wire.pendingAttempts
    }

    init(from decoder: any Decoder) throws { try self.init(Wire(from: decoder)) }

    func encode(to encoder: any Encoder) throws {
        try Wire(format: Self.currentFormat, identity: identity, revision: revision, phase: phase,
                 attemptIDs: attemptIDs, pendingAttempts: pendingAttempts).encode(to: encoder)
    }
}
