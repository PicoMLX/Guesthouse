import Darwin
import Dispatch
import Foundation
import GuesthouseCore

/// Single runtime owner of saved metadata (MVP §3, ADR 0004, #76).
/// Adapted from #217's snapshot store; the directory lock now spans the owner's lifetime,
/// replacing peer-observation state. No provider or guest-disk operation is performed here.
public actor StateStore {
    private var anchor: StateDirectoryAnchor?
    private let hooks: StateStoreHooks
    private var canSave = false
    private var snapshotWasPresent = false
    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private init(anchor: sending StateDirectoryAnchor, hooks: StateStoreHooks, queue: DispatchSerialQueue) {
        self.anchor = anchor
        self.hooks = hooks
        self.queue = queue
    }

    /// Reopen the runtime-selected, already prepared layout without creating or repairing it.
    /// Missing/insecure storage requires explicit setup/repair; opening establishes no readiness.
    public static func open() async throws(StateStoreError) -> StateStore {
        try await open(storage: { try RuntimeStorage(existingRoot: RuntimeStorage.defaultRoot()) })
    }

    static func open(storage: @escaping @Sendable () throws -> RuntimeStorage,
                     hooks: StateStoreHooks = StateStoreHooks()) async throws(StateStoreError) -> StateStore {
        // Keep blocking filesystem calls off the cooperative pool and the GUI's main actor.
        let queue = DispatchSerialQueue(label: "ai.picomlx.guesthouse.state-store", qos: .utility)
        let result: Result<StateStore, StateStoreError> = await withCheckedContinuation { continuation in
            queue.async {
                let result: Result<StateStore, StateStoreError>
                do {
                    let anchor = try StateDirectoryAnchor(storage: storage())
                    try anchor.withDescriptor { descriptor in
                        guard StateFileIO.lock(descriptor, LOCK_EX | LOCK_NB) else {
                            throw StateStoreError.fileUnwritable(name: .stateDirectory)
                        }
                    }
                    try anchor.synchronizePreparation()
                    result = .success(StateStore(anchor: anchor, hooks: hooks, queue: queue))
                } catch let failure as StateStoreError { result = .failure(failure) }
                catch StorageFailure.protectionDrift { result = .failure(.insecureDirectory(reason: .permissions)) }
                catch StorageFailure.unsafeStructure { result = .failure(.insecureDirectory(reason: .changed)) }
                catch { result = .failure(.insecureDirectory(reason: .unreadable)) }
                continuation.resume(returning: result)
            }
        }
        return try result.get()
    }

    /// Releases ownership after earlier synchronous actor transactions complete. No disk is deleted.
    /// The runtime must quiesce its operations before closing. This store cannot be reopened in place.
    public func close() { canSave = false; anchor = nil }

    /// Missing metadata is an empty inventory, never authority to recreate a VM.
    /// A successful read permits metadata saving, not host/guest mutations or job replay.
    public func loadSnapshot() throws(StateStoreError) -> EnvironmentsSnapshot {
        canSave = false
        guard let anchor else { throw .fileUnreadable(name: .stateDirectory) }
        let value = try readSnapshot(anchor)
        canSave = true
        return value
    }

    /// Requires this owner to load first. A failed publication blocks subsequent saves until
    /// explicitly reloaded; even an error after rename may have made the new snapshot visible.
    public func saveSnapshot(_ snapshot: EnvironmentsSnapshot) throws(StateStoreError) {
        guard let anchor, canSave else { throw .fileUnwritable(name: .snapshot) }
        canSave = false
        try snapshot.validate()
        let data: Data
        do { data = try JSONEncoder().encode(snapshot) }
        catch { throw .unencodable(name: .snapshot) }
        guard data.count <= StateFileIO.maximumSnapshotBytes else { throw .unencodable(name: .snapshot) }
        // Preserve unsupported/corrupt on-disk records even if the proposed value is valid.
        _ = try readSnapshot(anchor)
        try anchor.withDescriptor { directory in
            // One fixed exclusive temporary bounds interrupted-save debris. An existing entry
            // requires explicit repair; never collect or overwrite evidence from another attempt.
            let temporary = ".environments.json.pending"
            let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw StateStoreError.fileUnwritable(name: .snapshot) }
            defer { Darwin.close(descriptor) }
            var published = false
            defer { if !published { _ = unlinkat(directory, temporary, 0) } }
            try StateFileProtection.prepare(descriptor, kind: .regularFile, name: .snapshot)
            try hooks.write(descriptor, data)
            try hooks.synchronize(descriptor, .snapshot)
            guard renameat(directory, temporary, directory, StateFileAccess.readSnapshot.name) == 0 else {
                throw StateStoreError.fileUnwritable(name: .snapshot)
            }
            published = true
            snapshotWasPresent = true
            try hooks.synchronize(directory, .stateDirectory)
        }
        canSave = true
    }

    private func readSnapshot(_ anchor: StateDirectoryAnchor) throws(StateStoreError) -> EnvironmentsSnapshot {
        let value = try anchor.withFile(.readSnapshot, body: { descriptor in
            let raw = try StateFileIO.readAll(descriptor, from: 0, name: .snapshot)
            let migrated = try SnapshotMigrator.standard.migrate(raw)
            do { return try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrated.data) }
            catch let failure as StateStoreError { throw failure }
            catch { throw StateStoreError.corruptSnapshot }
        })
        guard value != nil || !snapshotWasPresent else { throw .fileUnreadable(name: .snapshot) }
        snapshotWasPresent = value != nil
        return value ?? .empty
    }
}

/// Internal synchronous fault seams. Borrowed descriptors never escape or cross a suspension.
struct StateStoreHooks: Sendable {
    var write: @Sendable (Int32, Data) throws -> Void = { try StateFileIO.writeAll($0, $1, name: .snapshot) }
    var synchronize: @Sendable (Int32, StateStoreError.File) throws -> Void = {
        try StateFileIO.fullySynchronize($0, name: $1)
    }
}
