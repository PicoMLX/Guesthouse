import Darwin
import Dispatch
import Foundation
import GuesthouseCore

/// Runtime-owned persistence, migrated from #57/#76 (MVP-PLAN.md §3). One owner per managed
/// state area; the GUI sees only Core values/errors, never a root URL or borrowed descriptor.
/// Snapshot operations are complete synchronous actor transactions: there is no suspension
/// between validation and publication. Journal/recovery integration is still a separate step.
public actor StateStore {
    private let anchor: StateDirectoryAnchor
    private let migrator: SnapshotMigrator
    private let hooks: StateStoreHooks
    private nonisolated let queue: DispatchSerialQueue

    /// Native descriptor IO/flushes and advisory lock waits may block. Use Dispatch's supplied
    /// serial executor instead of blocking Swift's cooperative pool or the caller's MainActor.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private init(anchor: sending StateDirectoryAnchor, migrator: SnapshotMigrator,
                 hooks: StateStoreHooks, queue: DispatchSerialQueue) {
        self.anchor = anchor
        self.migrator = migrator
        self.hooks = hooks
        self.queue = queue
    }

    /// Select and prepare the runtime's fixed managed storage. No caller-selected path API.
    /// Opening does not create a snapshot/journal or claim any VM/guest is ready.
    public static func open() async throws(StateStoreError) -> StateStore {
        try await open(storage: { try RuntimeStorage() })
    }

    /// Internal fixture/runtime composition seam. Hooks are Sendable before crossing onto
    /// the queue; the descriptor owner is created there and transferred exclusively to us.
    static func open(
        storage: @escaping @Sendable () throws -> RuntimeStorage,
        migrator: SnapshotMigrator = .standard, hooks: StateStoreHooks = StateStoreHooks()
    ) async throws(StateStoreError) -> StateStore {
        let queue = DispatchSerialQueue(label: "ai.picomlx.guesthouse.state-store", qos: .utility)
        let result: Result<StateStore, StateStoreError> = await withCheckedContinuation { continuation in
            queue.async {
                let result: Result<StateStore, StateStoreError>
                do {
                    let anchor = try StateDirectoryAnchor(storage: storage(), closeDirectory: { descriptor in
                        close(descriptor)
                        hooks.didCloseDirectory()
                    })
                    // No actor reference escapes until ALL preparation barriers succeed.
                    // A failed preparation releases the local anchor and preserves disk evidence.
                    try anchor.synchronizePreparation(barrier: hooks.preparation)
                    result = .success(StateStore(anchor: anchor, migrator: migrator, hooks: hooks, queue: queue))
                } catch let failure as StateStoreError { result = .failure(failure) }
                catch StorageFailure.protectionDrift { result = .failure(.insecureDirectory(reason: .permissions)) }
                catch StorageFailure.unsafeStructure { result = .failure(.insecureDirectory(reason: .changed)) }
                catch is StorageFailure { result = .failure(.insecureDirectory(reason: .unreadable)) }
                catch { result = .failure(.fileUnwritable(name: .stateDirectory)) }
                continuation.resume(returning: result)
            }
        }
        return try result.get()
    }

    /// Missing state means an empty snapshot, not permission to create or rewrite files.
    /// Explicit migrations run in memory; reading never rewrites their source document.
    public func loadSnapshot() throws(StateStoreError) -> EnvironmentsSnapshot {
        try anchor.withFile(.readSnapshot, permissionBarrier: hooks.permission, body: { descriptor in
            let raw = try StateFileIO.readAll(descriptor, from: 0, name: .snapshot)
            let migrated = try migrator.migrate(raw)
            do { return try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrated.data) }
            catch let failure as StateStoreError { throw failure }
            catch { throw StateStoreError.corruptSnapshot }
        }) ?? .empty
    }

    /// Return only after the full verified publication completes. Cancellation does not abort
    /// an in-progress synchronous transaction. On failure retain evidence and inspect; never
    /// assume a failed save restored the old bytes or blindly repeat the associated operation.
    public func saveSnapshot(_ snapshot: EnvironmentsSnapshot) throws(StateStoreError) {
        try StateSnapshotPublication.save(snapshot, to: anchor, migrator: migrator,
            permissionBarrier: hooks.permission, fileBarrier: hooks.snapshotFile, directoryBarrier: hooks.directory)
    }
}

/// Internal synchronous fault/lifetime seams, not a diagnostic sink or an XPC API.
/// No callback may retain, close or transfer a borrowed descriptor, or suspend a transaction.
struct StateStoreHooks: Sendable {
    typealias Barrier = @Sendable (Int32, StateStoreError.File) throws -> Void
    var preparation: Barrier = { try StateFileIO.fullySynchronize($0, name: $1) }
    var permission: Barrier = { try StateFileIO.fullySynchronize($0, name: $1) }
    var snapshotFile: Barrier = { try StateFileIO.fullySynchronize($0, name: $1) }
    var directory: Barrier = { try StateFileIO.fullySynchronize($0, name: $1) }
    var didCloseDirectory: @Sendable () -> Void = {}
}
