import Darwin
import GuesthouseCore

/// Fixed runtime operations, never arbitrary GUI/repository names or snapshot-in-place writes.
enum StateFileAccess: Sendable, CaseIterable {
    case readSnapshot, readJournal, writeJournal

    var name: String { self == .readSnapshot ? "environments.json" : "journal.ndjson" }
    var label: StateStoreError.File { self == .readSnapshot ? .snapshot : .journal }
    var creates: Bool { self == .writeJournal }
    var failure: StateStoreError { creates ? .fileUnwritable(name: label) : .fileUnreadable(name: label) }
}

extension StateDirectoryAnchor {
    /// Scoped file ownership adapted from #57 (MVP-PLAN.md §3). All borrowed descriptors stay
    /// inside this synchronous call; do not retain/close them or suspend the transaction.
    /// The caller must synchronize preparation before accepting store operations. This opens
    /// and protects files, but neither appends a record nor makes a new file's entry durable.
    /// A journal caller must classify ANY failure after its write attempt, including post-checks,
    /// as uncertain, and only publish cache/operation results after this entire call succeeds.
    func withFile<Result>(
        _ access: StateFileAccess,
        permissionBarrier: StateFileProtection.Barrier = { try StateFileIO.fullySynchronize($0, name: $1) },
        didOpen: () -> Void = {},
        didObserve: () -> Void = {},
        body: (Int32) throws -> Result
    ) throws(StateStoreError) -> Result? {
        try withDescriptor { directory in
            try StateFileEntry.withDescriptor(in: directory, access: access,
                permissionBarrier: permissionBarrier, didOpen: didOpen, didObserve: didObserve,
                validateDirectory: { try self.verifyCurrent(version: $0) }, body: body)
        }
    }
}

/// One descriptor and one exclusive advisory lock span protection, work, and final checks.
/// Even reads may repair metadata, so they also lock exclusively; do not downgrade or upgrade
/// mid-transaction. Darwin flock(2) releases the previous lock during either conversion.
/// This serializes cooperating stores, not arbitrary same-user namespace changes.
enum StateFileEntry {
    static func withDescriptor<Result>(
        in directory: Int32, access: StateFileAccess, requireExisting: Bool = false,
        permissionBarrier: StateFileProtection.Barrier,
        didOpen: () -> Void = {},
        didObserve: () -> Void = {},
        validateDirectory: (StateFileVersion?) throws -> Void,
        body: (Int32) throws -> Result
    ) throws(StateStoreError) -> Result? {
        // Once a journal was observed, disappearance must not silently create a new history.
        let flags = (access.creates ? O_RDWR : O_RDONLY)
            | (access.creates && !requireExisting ? O_CREAT : 0) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var descriptor = openat(directory, access.name, flags, 0o600)
        // Retained bounded retry for a transient missing entry during creation. No bytes are
        // truncated and no VM/Git mutation is retried. Missing read-only files remain absent.
        var remaining = 4
        while descriptor < 0, access.creates, !requireExisting, errno == ENOENT, remaining > 0 {
            remaining -= 1
            descriptor = openat(directory, access.name, flags, 0o600)
        }
        guard descriptor >= 0 else {
            // Only a stabilized ENOENT proves absence. Other failures may hide an existing
            // entry (permission drift, symlink, descriptor exhaustion); retain that uncertainty.
            let openError = errno
            if openError != ENOENT { didObserve() }
            if openError == ENOENT, !access.creates {
                do {
                    let version = try StateFileIO.version(directory, name: .stateDirectory)
                    try validateDirectory(version)
                    var entry = stat()
                    // Stabilize the missing observation before publishing an empty value. A
                    // newly created entry is evidence to inspect, not an automatic read retry.
                    guard fstatat(directory, access.name, &entry, AT_SYMLINK_NOFOLLOW) == -1,
                          errno == ENOENT else { throw access.failure }
                    try validateDirectory(version)
                    return nil
                } catch let failure as StateStoreError {
                    didObserve() // Failed stabilization cannot prove continued absence.
                    throw failure
                } catch {
                    didObserve()
                    throw access.failure
                }
            }
            if openError == ELOOP { throw .insecureDirectory(reason: .symbolicLink) }
            throw access.failure
        }
        defer { close(descriptor) } // Closing the sole open description also releases its lock.
        // Opening is already an observation, even if structure, locking or protection fails.
        // No descriptor escapes; this cannot imply validated contents or durability.
        didOpen()
        didObserve()
        do {
            // Refuse FIFOs/directories/links before a lock or metadata repair. NONBLOCK keeps
            // opening an unexpected FIFO from waiting for a peer before this inspection.
            try requireBinding(descriptor, in: directory, access: access)
            guard StateFileIO.lock(descriptor, LOCK_EX) else { throw access.failure }
            try validateDirectory(nil)
            try requireBinding(descriptor, in: directory, access: access)
            try StateFileProtection.prepare(descriptor, kind: .regularFile, name: access.label,
                synchronize: { descriptor, label in
                    let fileVersion = try StateFileIO.version(descriptor, name: label)
                    let directoryVersion = try StateFileIO.version(directory, name: .stateDirectory)
                    try permissionBarrier(descriptor, label)
                    try verifyCurrent(descriptor, in: directory, access: access, version: fileVersion)
                    try validateDirectory(directoryVersion)
                })
            try validateDirectory(nil)
            let prepared = try verifyCurrent(descriptor, in: directory, access: access)
            let result = try body(descriptor)
            try verifyCurrent(descriptor, in: directory, access: access, version: access.creates ? nil : prepared)
            try validateDirectory(nil)
            return result
        } catch let error as StateStoreError { throw error }
        catch { throw access.failure }
    }

    /// In addition to inode identity, a supplied version detects same-inode reattachment or
    /// rewriting across a publication/read barrier. Writers capture their own post-write version.
    @discardableResult static func verifyCurrent(
        _ descriptor: Int32, in directory: Int32, access: StateFileAccess, version: StateFileVersion? = nil
    ) throws(StateStoreError) -> StateFileVersion {
        let info = try StateFileProtection.verify(descriptor, kind: .regularFile)
        let entry = try requireBinding(descriptor, in: directory, access: access)
        let actual = StateFileVersion(info)
        if let version, actual != version || StateFileVersion(entry) != version {
            throw .fileUnwritable(name: access.label)
        }
        return actual
    }

    @discardableResult private static func requireBinding(
        _ descriptor: Int32, in directory: Int32, access: StateFileAccess
    ) throws(StateStoreError) -> stat {
        var opened = stat(), entry = stat()
        guard fstat(descriptor, &opened) == 0 else { throw access.failure }
        try StateFileProtection.validateStructure(opened, kind: .regularFile)
        guard fstatat(directory, access.name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              StateFileIdentity(opened) == StateFileIdentity(entry) else {
            throw .fileUnwritable(name: access.label)
        }
        try StateFileProtection.validateStructure(entry, kind: .regularFile)
        return entry
    }
}
