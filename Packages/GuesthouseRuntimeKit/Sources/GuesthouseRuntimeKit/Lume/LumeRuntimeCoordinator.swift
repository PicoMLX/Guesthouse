import Foundation
import GuesthouseCore

public enum LumeRuntimeCoordinationError: Error, Hashable, Sendable, LocalizedError {
    case nestedAcquisition

    public var userMessage: String {
        "Guesthouse tried to acquire a Lume runtime lease while the operation already held one."
    }

    public var recoveryActions: [RecoveryAction] { [.cancel] }

    public var errorDescription: String? { userMessage }
}

private enum LumeRuntimeLeaseContext {
    @TaskLocal static var heldLeases: [RuntimeStorage.CoordinationIdentity: UInt64] = [:]
}

/// Serializes every operation that can launch or replace Guesthouse's private Lume runtime.
///
/// Lume writes configuration even for help commands, and a verified app bundle must not be
/// replaced between verification and launch. Probes and every future install, update, repair,
/// or removal operation therefore share this coordinator and hold it for their whole operation.
/// Processes running independently as the signed-in host user are outside Guesthouse's
/// containment boundary.
///
/// Operations may use structured child tasks, which inherit the lease context, but must not
/// await a `Task.detached` that re-enters this coordinator. Detached tasks cannot inherit Swift
/// task-local ownership, so awaiting such a reacquisition while holding a lease would deadlock.
public actor LumeRuntimeCoordinator {
    public static let shared = LumeRuntimeCoordinator()

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<UInt64, any Error>
    }

    private struct LeaseState {
        var owner: UInt64
        var waiters: [Waiter]
    }

    /// Dictionary presence means the physical root's lease is held. Owner tokens distinguish an
    /// active inherited task-local lease from stale context in an unstructured child task.
    private var statesByRoot: [RuntimeStorage.CoordinationIdentity: LeaseState] = [:]
    private var nextToken: UInt64 = 0
    private let onWaiterQueued: (@Sendable () -> Void)?

    init(onWaiterQueued: (@Sendable () -> Void)? = nil) {
        self.onWaiterQueued = onWaiterQueued
    }

    public func withExclusiveAccess<T: Sendable>(
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
            // concurrent A→B and B→A operations can deadlock. Detached tasks do not inherit this
            // context and must never be awaited while re-entering the coordinator.
            throw LumeRuntimeCoordinationError.nestedAcquisition
        }
        let token = try await acquire(key)
        defer { release(key, owner: token) }
        try Task.checkCancellation()
        var heldLeases = LumeRuntimeLeaseContext.heldLeases
        heldLeases[key] = token
        return try await LumeRuntimeLeaseContext.$heldLeases.withValue(heldLeases) {
            try await operation()
        }
    }

    private func acquire(_ key: RuntimeStorage.CoordinationIdentity) async throws -> UInt64 {
        let token = makeToken()
        guard statesByRoot[key] != nil else {
            statesByRoot[key] = LeaseState(owner: token, waiters: [])
            return token
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt64, any Error>) in
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

    private func makeToken() -> UInt64 {
        defer { nextToken &+= 1 }
        return nextToken
    }

    private func cancelWaiter(id: UInt64, for key: RuntimeStorage.CoordinationIdentity) {
        guard var state = statesByRoot[key],
              let index = state.waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = state.waiters.remove(at: index)
        statesByRoot[key] = state
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: RuntimeStorage.CoordinationIdentity, owner: UInt64) {
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
