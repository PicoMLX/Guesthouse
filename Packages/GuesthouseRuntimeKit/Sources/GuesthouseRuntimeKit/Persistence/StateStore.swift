import Darwin
import Dispatch
import Foundation
import GuesthouseCore

/// Runtime-owned persistence, migrated from #57/#76 (MVP-PLAN.md §3). One owner per managed
/// state area; the GUI sees only Core values/errors, never a root URL or borrowed descriptor.
/// Snapshot and journal operations are complete synchronous actor transactions: there is no
/// suspension between validation and publication. They never execute the recorded mutation.
public actor StateStore {
    private let anchor: StateDirectoryAnchor
    private let migrator: SnapshotMigrator
    private let hooks: StateStoreHooks
    private var journal = StateJournalCache()
    private var journalObservation = StateJournalObservation()
    // This observation survives cache invalidation and failed parsing/post-checks.
    private var journalWasObserved = false
    // Observation survives failed reads/publications. Absence after observation is evidence
    // loss, never an empty new store. This is actor-confined and never reset by an error.
    private var snapshotWasObserved = false
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
        let snapshot = try anchor.withFile(.readSnapshot, permissionBarrier: hooks.permission,
            didObserve: { self.snapshotWasObserved = true }, body: { descriptor in
            let raw = try StateFileIO.readAll(descriptor, from: 0, name: .snapshot)
            let migrated = try migrator.migrate(raw)
            do { return try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrated.data) }
            catch let failure as StateStoreError { throw failure }
            catch { throw StateStoreError.corruptSnapshot }
        })
        guard snapshot != nil || !snapshotWasObserved else { throw .fileUnreadable(name: .snapshot) }
        return snapshot ?? .empty
    }

    /// Return only after the full verified publication completes. Cancellation does not abort
    /// an in-progress synchronous transaction. On failure retain evidence and inspect; never
    /// assume a failed save restored the old bytes or blindly repeat the associated operation.
    public func saveSnapshot(_ snapshot: EnvironmentsSnapshot) throws(StateStoreError) {
        try StateSnapshotPublication.save(snapshot, to: anchor, migrator: migrator,
            requireExisting: snapshotWasObserved, didObserve: { self.snapshotWasObserved = true },
            permissionBarrier: hooks.permission, fileBarrier: hooks.snapshotFile, directoryBarrier: hooks.directory)
    }

    /// Returns an identity only after the started record's complete write/barrier checks.
    /// A failure may leave evidence on disk; inspect rather than blindly retry the operation.
    public func begin(
        _ operation: JournalOperation, for environmentID: EnvironmentID, at timestamp: Date = Date()
    ) throws(StateStoreError) -> OperationID {
        let id = OperationID()
        try append(JournalRecord(id: id, environmentID: environmentID, operation: operation,
                                 timestamp: timestamp, outcome: .started))
        return id
    }

    /// Retains exact operation identity and unknown outcomes. Only an incomplete final line
    /// may be truncated; unsupported/corrupt complete records refuse publication unchanged.
    public func append(_ record: JournalRecord) throws(StateStoreError) {
        do {
            // Adopt only after ALL outer file-entry and directory checks have returned.
            journal = try StateJournalAppend.append(record, to: anchor, observation: &journalObservation, hooks: hooks,
                requireExisting: journalWasObserved, didObserve: { journalWasObserved = true })
        } catch {
            journal = StateJournalCache()
            throw error
        }
    }

    /// Replay never creates or truncates the journal. Torn bytes remain available for later
    /// inspected recovery; complete invalid/unsupported records refuse the whole result.
    /// Observing these records is not proof of their durability or any mutation's outcome.
    public func replay() throws(StateStoreError) -> JournalReplay {
        do {
            let candidate = try anchor.withFile(.readJournal, permissionBarrier: hooks.permission,
                                                didObserve: { journalWasObserved = true },
                                                didIdentify: { journalObservation.identify($0) }) {
                return try journalObservation.refreshed($0, read: hooks.journalRead)
            }
            guard candidate != nil || !journalWasObserved else {
                throw StateStoreError.fileUnreadable(name: .journal)
            }
            // Adoption happens only after all outer entry and directory checks. Missing
            // state is empty only before this owner has ever observed a journal.
            journal = candidate ?? StateJournalCache()
            return journal.replay
        } catch {
            journal = StateJournalCache()
            throw error
        }
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
    var journalFile: Barrier = { try StateFileIO.fullySynchronize($0, name: $1) }
    var journalWrite: @Sendable (Int32, Data) throws -> Void = { try StateFileIO.writeAll($0, $1, name: .journal) }
    var journalRead: StateJournalCache.Reader = { try StateFileIO.readAll($0, from: $1, name: .journal) }
    var didCloseDirectory: @Sendable () -> Void = {}
}
