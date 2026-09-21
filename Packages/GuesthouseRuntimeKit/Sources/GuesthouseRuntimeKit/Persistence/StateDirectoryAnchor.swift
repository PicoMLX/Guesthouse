import Darwin
import Foundation
import GuesthouseCore

/// Owns the fixed state directory, adapting #57's retained-directory checks (MVP-PLAN.md §3).
/// Intentionally non-Sendable: keep this owner inside the future StateStore actor. Borrowing is
/// synchronous, nonescaping, and does not transfer/duplicate descriptor ownership. Never close
/// or retain the borrowed descriptor, or suspend a transaction while using it.
///
/// Construction is read-only. Explicit preparation synchronization is separate from file locks,
/// file-entry checks and transactional publication; it does not authorize a VM mutation.
/// Namespace/protection checks are point-in-time observations, not immunity to same-user races.
final class StateDirectoryAnchor {
    private let storage: RuntimeStorage
    private let descriptor: Int32
    private let identity: StateFileIdentity
    private let closeDirectory: (Int32) -> Void

    /// Runtime-only native seams for deterministic open-race/lifetime tests. Not an XPC API.
    init(
        storage: RuntimeStorage,
        openDirectory: (String, Int32) -> Int32 = { open($0, $1) },
        closeDirectory: @escaping (Int32) -> Void = { close($0) }
    ) throws(StateStoreError) {
        var observed: StateFileIdentity?
        let path = try Self.currentPath(storage, didObserve: { observed = $0 })
        let descriptor = openDirectory(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .insecureDirectory(reason: .unopenable) }
        let identity: StateFileIdentity
        do throws(StateStoreError) {
            identity = StateFileIdentity(try StateFileProtection.verify(descriptor, kind: .directory))
            guard identity == observed else { throw StateStoreError.insecureDirectory(reason: .changed) }
            try Self.verify(storage, descriptor: descriptor, identity: identity, version: nil)
        } catch {
            closeDirectory(descriptor)
            throw error
        }
        // Ownership transfers only after every throwing check. A failed initializer must not
        // also run a fully initialized owner's deinit and close a potentially reused descriptor.
        self.storage = storage
        self.descriptor = descriptor
        self.identity = identity
        self.closeDirectory = closeDirectory
    }

    deinit { closeDirectory(descriptor) }

    /// Retains #57's startup barriers even for already-visible directories left by an interrupted
    /// preparation. Call before accepting store operations; there is no cached "already durable"
    /// flag. This flushes the state directory and its ancestry, not other managed storage areas.
    func synchronizePreparation(
        barrier: StateFileProtection.Barrier = { try StateFileIO.fullySynchronize($0, name: $1) }
    ) throws(StateStoreError) {
        try withDescriptor { descriptor in
            let version = try verifyCurrent()
            let path = try Self.currentPath(storage)
            let physical = try StateDirectoryDurability.resolve(path)
            // Preserve the original leaf-metadata barrier before parent-entry barriers.
            try barrier(descriptor, .stateDirectory)
            try verifyCurrent(version: version)
            for parent in StateDirectoryDurability.parents(lexical: path, physical: physical) {
                try verifyCurrent(version: version)
                guard try StateDirectoryDurability.resolve(path) == physical else {
                    throw StateStoreError.insecureDirectory(reason: .changed)
                }
                try StateDirectoryDurability.synchronize(parent, barrier: barrier)
                try verifyCurrent(version: version)
            }
            guard try StateDirectoryDurability.resolve(path) == physical else {
                throw StateStoreError.insecureDirectory(reason: .changed)
            }
        }
    }

    /// Capture immediately before a publication barrier, then pass that version afterward to
    /// refuse same-inode reattachment. Ordinary directory writes legitimately change versions;
    /// never compare all future operations against the initialization-time timestamp.
    @discardableResult func verifyCurrent(version: StateFileVersion? = nil) throws(StateStoreError) -> StateFileVersion {
        try Self.verify(storage, descriptor: descriptor, identity: identity, version: version)
    }

    /// Checks protection/current binding before entry and after successful work. If work throws,
    /// its closed failure is preserved. A post-check failure does not undo any attempted write.
    func withDescriptor<Result>(_ body: (Int32) throws -> Result) throws(StateStoreError) -> Result {
        try verifyCurrent()
        let result: Result
        do { result = try body(descriptor) }
        catch let error as StateStoreError { throw error }
        catch { throw .fileUnwritable(name: .stateDirectory) }
        try verifyCurrent()
        return result
    }

    @discardableResult private static func verify(
        _ storage: RuntimeStorage, descriptor: Int32, identity: StateFileIdentity, version: StateFileVersion?
    ) throws(StateStoreError) -> StateFileVersion {
        // Recheck managed parents, lexical/canonical ancestry, ACLs and backup-policy drift,
        // not just the final inode. A previously returned RuntimeStorage URL is not a lease.
        let path = try currentPath(storage)
        let anchored = try StateFileProtection.verify(descriptor, kind: .directory)
        var current = stat()
        guard lstat(path, &current) == 0,
              StateFileIdentity(anchored) == identity, StateFileIdentity(current) == identity else {
            throw .insecureDirectory(reason: .changed)
        }
        try StateFileProtection.validateStructure(current, kind: .directory)
        guard current.st_mode & 0o7777 == 0o700 else { throw .insecureDirectory(reason: .permissions) }
        let actual = StateFileVersion(anchored)
        if let version, actual != version || StateFileVersion(current) != version {
            throw .insecureDirectory(reason: .changed)
        }
        return actual
    }

    private static func currentPath(_ storage: RuntimeStorage,
                                    didObserve: (StateFileIdentity) -> Void = { _ in }) throws(StateStoreError) -> String {
        do { return try StorageProtection.path(storage.location(for: .state, didObserve: didObserve)) }
        catch StorageFailure.protectionDrift { throw .insecureDirectory(reason: .permissions) }
        catch StorageFailure.unsafeStructure { throw .insecureDirectory(reason: .changed) }
        catch { throw .insecureDirectory(reason: .unreadable) }
    }
}
