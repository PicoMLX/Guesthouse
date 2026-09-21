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
        _ access: StateFileAccess, requireExisting: Bool = false,
        protection: StateFileEntry.Protection = .prepare,
        permissionBarrier: StateFileProtection.Barrier = { try StateFileIO.fullySynchronize($0, name: $1) },
        didOpen: () -> Void = {},
        didObserve: () -> Void = {},
        didIdentify: (StateFileIdentity?) -> Bool = { _ in true },
        body: (Int32) throws -> Result
    ) throws(StateStoreError) -> Result? {
        try withDescriptor { directory in
            try StateFileEntry.withDescriptor(in: directory, access: access, requireExisting: requireExisting,
                protection: protection,
                permissionBarrier: permissionBarrier, didOpen: didOpen, didObserve: didObserve,
                didIdentify: didIdentify,
                validateDirectory: { try self.verifyCurrent(version: $0) }, body: body)
        }
    }
}

/// One descriptor and one exclusive advisory lock span protection, work, and final checks.
/// Even reads may repair metadata, so they also lock exclusively; do not downgrade or upgrade
/// mid-transaction. Darwin flock(2) releases the previous lock during either conversion.
/// This serializes cooperating stores, not arbitrary same-user namespace changes.
enum StateFileEntry {
    enum Protection { case prepare, verifyOnly }

    static func withDescriptor<Result>(
        in directory: Int32, access: StateFileAccess, requireExisting: Bool = false,
        protection: Protection = .prepare,
        permissionBarrier: StateFileProtection.Barrier,
        openFile: (Int32, String, Int32, mode_t) -> Int32 = { openat($0, $1, $2, $3) },
        didOpen: () -> Void = {},
        didObserve: () -> Void = {},
        didIdentify: (StateFileIdentity?) -> Bool = { _ in true },
        validateDirectory: (StateFileVersion?) throws -> Void,
        body: (Int32) throws -> Result
    ) throws(StateStoreError) -> Result? {
        // Verify-only callers never open a writable/create-capable descriptor, even if a
        // future caller accidentally pairs the policy with a journal write operation.
        guard protection != .verifyOnly || !access.creates else { throw access.failure }
        // Once a journal was observed, disappearance must not silently create a new history.
        // Append placement must not overwrite a competing write after a prior EOF seek.
        let flags = (access.creates ? O_RDWR | O_APPEND : O_RDONLY)
            | (access.creates && !requireExisting ? O_CREAT : 0) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        // Pin the namespace before every verify-only open: success, absence and permission
        // guidance must all describe the same observation, not a replacement entry.
        let openingDirectoryVersion: StateFileVersion?
        if protection == .verifyOnly {
            openingDirectoryVersion = try StateFileIO.version(directory, name: .stateDirectory)
        } else { openingDirectoryVersion = nil }
        var descriptor = openFile(directory, access.name, flags, 0o600)
        // Retained bounded retry for a transient missing entry during creation. No bytes are
        // truncated and no VM/Git mutation is retried. Missing read-only files remain absent.
        var remaining = 4
        while descriptor < 0, access.creates, !requireExisting, errno == ENOENT, remaining > 0 {
            remaining -= 1
            descriptor = openFile(directory, access.name, flags, 0o600)
        }
        guard descriptor >= 0 else {
            let openFailure = errno
            // Non-ENOENT failures may hide an entry. Keep uncertainty even when verify-only
            // classification or protection checks below fail; this does not grant access.
            // A required-existing writer losing its entry is itself uncertain evidence.
            // Report it even on ENOENT so restoring the original cannot authorize append.
            // This runs only after an actual open failure, never on prior lock contention.
            if openFailure != ENOENT || (access.creates && requireExisting) {
                didObserve()
                guard didIdentify(entryIdentity(in: directory, access: access)) else { throw access.failure }
            }
            if openFailure == EACCES, protection == .verifyOnly {
                do {
                    guard let version = openingDirectoryVersion else { throw access.failure }
                    try validateDirectory(version)
                    var denied = stat(), current = stat()
                    guard fstatat(directory, access.name, &denied, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw access.failure
                    }
                    try StateFileProtection.validateStructure(denied, kind: .regularFile)
                    try validateDirectory(version)
                    guard fstatat(directory, access.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          StateFileVersion(denied) == StateFileVersion(current) else {
                        throw StateStoreError.insecureDirectory(reason: .changed)
                    }
                    try StateFileProtection.validateStructure(current, kind: .regularFile)
                    // A bound, owned regular file denied O_RDONLY access. Both restrictive
                    // modes and deny-read ACLs need protection guidance, never silent repair.
                    throw StateStoreError.insecureDirectory(reason: .permissions)
                } catch let failure as StateStoreError { throw failure }
                catch { throw access.failure }
            }
            if openFailure == ENOENT, !access.creates {
                do {
                    let version = try openingDirectoryVersion ?? StateFileIO.version(directory, name: .stateDirectory)
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
                    _ = didIdentify(entryIdentity(in: directory, access: access))
                    throw failure
                } catch {
                    didObserve()
                    _ = didIdentify(entryIdentity(in: directory, access: access))
                    throw access.failure
                }
            }
            if openFailure == ELOOP { throw .insecureDirectory(reason: .symbolicLink) }
            throw access.failure
        }
        defer { close(descriptor) } // Closing the sole open description also releases its lock.
        // Opening is already an observation, even if structure, locking or protection fails.
        // No descriptor escapes; this cannot imply validated contents or durability.
        didOpen()
        didObserve()
        var opened = stat()
        let observedIdentity = fstat(descriptor, &opened) == 0 ? StateFileIdentity(opened) : nil
        guard didIdentify(observedIdentity) else { throw access.failure }
        do {
            // Refuse FIFOs/directories/links before a lock or metadata repair. NONBLOCK keeps
            // opening an unexpected FIFO from waiting for a peer before this inspection.
            try requireBinding(descriptor, in: directory, access: access)
            guard StateFileIO.lock(descriptor, LOCK_EX) else { throw access.failure }
            // Creation, if needed, precedes this boundary. File-content writes never need
            // to change the directory namespace; pin it across preparation and the body.
            let transactionDirectoryVersion = try openingDirectoryVersion ?? StateFileIO.version(directory, name: .stateDirectory)
            try validateDirectory(transactionDirectoryVersion)
            try requireBinding(descriptor, in: directory, access: access)
            switch protection {
            case .verifyOnly:
                try StateFileProtection.verify(descriptor, kind: .regularFile)
            case .prepare:
                try StateFileProtection.prepare(descriptor, kind: .regularFile, name: access.label,
                    synchronize: { descriptor, label in
                        let fileVersion = try StateFileIO.version(descriptor, name: label)
                        let directoryVersion = try StateFileIO.version(directory, name: .stateDirectory)
                        try permissionBarrier(descriptor, label)
                        try verifyCurrent(descriptor, in: directory, access: access, version: fileVersion)
                        try validateDirectory(directoryVersion)
                    })
            }
            try validateDirectory(transactionDirectoryVersion)
            let prepared = try verifyCurrent(descriptor, in: directory, access: access)
            let result = try body(descriptor)
            try verifyCurrent(descriptor, in: directory, access: access, version: access.creates ? nil : prepared)
            try validateDirectory(transactionDirectoryVersion)
            return result
        } catch let error as StateStoreError { throw error }
        catch { throw access.failure }
    }

    /// Nofollow metadata for failed opens only. An identity is evidence, not valid contents
    /// or access authority; inability to bind it is reported explicitly to the owner.
    private static func entryIdentity(in directory: Int32, access: StateFileAccess) -> StateFileIdentity? {
        var entry = stat()
        return fstatat(directory, access.name, &entry, AT_SYMLINK_NOFOLLOW) == 0 ? StateFileIdentity(entry) : nil
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
