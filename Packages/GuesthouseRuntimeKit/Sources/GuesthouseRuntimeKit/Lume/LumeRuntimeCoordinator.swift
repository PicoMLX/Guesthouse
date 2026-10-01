import Foundation
import GuesthouseCore

enum LumeRuntimeCoordinationError: Error, Hashable, Sendable, LocalizedError {
    case nestedAcquisition

    var userMessage: String {
        "Guesthouse tried to acquire a Lume runtime lease while the operation already held one."
    }

    var recoveryActions: [RecoveryAction] { [.cancel] }

    var errorDescription: String? { userMessage }
}

private enum LumeRuntimeLeaseContext {
    @TaskLocal static var heldLeases: [StateFileIdentity: UUID] = [:]
}

/// Retained #87 lease policy migrated onto existing storage/identity checks (MVP §§3–4).
/// Serializes cooperating access to Guesthouse's private runtime root inside this service.
/// Use `shared` for production. This is not a second metadata writer or a cross-process lock:
/// the service must first own its existing StateStore before admitting managed mutations.
///
/// Returning/throwing releases the lease. Never return while a launched child or descendant
/// may still use the runtime: a timeout, canceled waiter or delivered signal is not quiescence.
/// Provider execution remains disabled pending the ownership/restart proof in #84/#82; this
/// slice does not resolve that finding or authorize a process launch. A future provider owner
/// must retain authority beyond the caller and reconcile unknown outcomes before replacement.
///
/// Lume writes configuration even for help commands, and a verified app bundle must not be
/// replaced between verification and launch. Probes and every future install, update, repair,
/// or removal operation therefore share this coordinator and hold it for their whole operation.
/// Processes running independently as the signed-in host user are outside Guesthouse's
/// containment boundary. These rules implement MVP-PLAN.md §3 ("Sandbox and XPC boundary"
/// and "Local storage") and §4 ("Runtime delivery and console").
///
/// Operations may use child tasks that inherit the active lease context, but must not await
/// any task that re-enters this coordinator without that context. This includes `Task.detached`
/// and an ordinary unstructured `Task` created before the operation acquired its lease. Such a
/// task queues behind the current owner, so awaiting its reacquisition would deadlock.
actor LumeRuntimeCoordinator {
    static let shared = LumeRuntimeCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, any Error>
    }

    private struct LeaseState {
        var owner: UUID
        var waiters: [Waiter]
    }

    /// Dictionary presence means the physical root's lease is held. Owner tokens distinguish an
    /// active inherited task-local lease from stale context in an unstructured child task.
    private var statesByRoot: [StateFileIdentity: LeaseState] = [:]
    private let onWaiterQueued: (@Sendable () -> Void)?

    init(onWaiterQueued: (@Sendable () -> Void)? = nil) {
        self.onWaiterQueued = onWaiterQueued
    }

    func withExclusiveAccess<T: Sendable>(
        for storage: RuntimeStorage,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let key = try storage.coordinationIdentity()
        let hasActiveInheritedLease = LumeRuntimeLeaseContext.heldLeases.contains { root, token in
            statesByRoot[root]?.owner == token
        }
        guard !hasActiveInheritedLease else {
            // Reject every active nested acquisition, not just same-root recursion: otherwise
            // concurrent A→B and B→A operations can deadlock. Tasks without inherited active
            // lease context must never be awaited while re-entering the coordinator.
            throw LumeRuntimeCoordinationError.nestedAcquisition
        }
        let token = try await acquire(key)
        defer { release(key, owner: token) }
        try Task.checkCancellation()
        guard try storage.coordinationIdentity() == key else { throw StorageFailure.unsafeStructure }
        var heldLeases = LumeRuntimeLeaseContext.heldLeases
        heldLeases[key] = token
        return try await LumeRuntimeLeaseContext.$heldLeases.withValue(heldLeases) {
            try await operation()
        }
    }

    private func acquire(_ key: StateFileIdentity) async throws -> UUID {
        let token = UUID()
        guard statesByRoot[key] != nil else {
            statesByRoot[key] = LeaseState(owner: token, waiters: [])
            return token
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    statesByRoot[key]?.waiters.append(Waiter(id: token, continuation: continuation))
                    onWaiterQueued?()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: token, for: key) }
        }
    }

    private func cancelWaiter(id: UUID, for key: StateFileIdentity) {
        guard var state = statesByRoot[key],
              let index = state.waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = state.waiters.remove(at: index)
        statesByRoot[key] = state
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: StateFileIdentity, owner: UUID) {
        guard var state = statesByRoot[key], state.owner == owner else { return }
        guard !state.waiters.isEmpty else {
            statesByRoot.removeValue(forKey: key)
            return
        }
        let next = state.waiters.removeFirst()
        state.owner = next.id
        statesByRoot[key] = state
        next.continuation.resume(returning: next.id)
    }
}

extension RuntimeStorage {
    /// Reuse the managed layout policy and common device/inode identity; no duplicate path
    /// normalization or storage implementation. Physical-root aliases coordinate together.
    /// A queued waiter rechecks this key after acquiring; replacing its root never transfers
    /// the old lease's authority to the new directory.
    func coordinationIdentity() throws -> StateFileIdentity {
        let runtime = try location(for: .runtime)
        return StateFileIdentity(try StorageProtection.structure(runtime.deletingLastPathComponent()))
    }
}
