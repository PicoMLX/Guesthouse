import Darwin
import Foundation
import GuesthouseCore

/// Persists the identities of processes the service launched, so a relaunched service can
/// recognize a survivor or refuse to guess (MVP-PLAN.md §4). Written atomically before the
/// process is reported as started; one file under the runtime's `state/` directory.
public actor ProcessIdentityStore {
    public static let fileName = "processes.json"

    /// The document holds one small record per managed environment. A file far larger than
    /// that was planted or restored, not written here, and reading it before saying so would
    /// mean allocating whatever it contains inside the service.
    static let maximumFileSize: off_t = 1 << 20

    public nonisolated let url: URL
    /// An open descriptor for the state directory this store was given. Every read, write,
    /// rename, removal and synchronization goes through it, so a directory renamed or replaced
    /// with a link after the store opened cannot redirect ownership evidence out of the
    /// runtime's own tree (MVP-PLAN.md §3, "Local storage").
    private nonisolated let directory: Int32
    /// The folder the store was given, so a write can confirm the descriptor still names it.
    private nonisolated let folder: URL
    private var identities: [EnvironmentID: ProcessIdentity]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Dates are stored as `Date`'s own value (seconds since the reference date, full double
    /// precision), so a start time reads back bit-for-bit: the reconciler compares it for
    /// equality with the kernel's value. Converting to another epoch would round.
    public init(directory folder: URL) throws {
        let file = folder.appending(path: Self.fileName)
        url = file
        self.folder = folder
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        jsonEncoder.dateEncodingStrategy = .deferredToDate
        encoder = jsonEncoder
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .deferredToDate
        decoder = jsonDecoder
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        // Thrown before `identities` is assigned, so the actor is never fully initialized and
        // no deinitializer runs for a descriptor that was never taken.
        guard descriptor >= 0 else {
            throw ProcessIdentityStoreError.unreadable(path: folder.path, reason: errno == ELOOP ? "the state folder is a symbolic link" : String(cString: strerror(errno)))
        }
        directory = descriptor
        do {
            // Leftovers from a write that was interrupted before its rename are removed first,
            // so repeated interruptions cannot fill the state volume with orphaned snapshots.
            Self.removeStaleTemporaries(in: descriptor)
            identities = try Self.load(from: descriptor, path: file.path, decoder: jsonDecoder)
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit { close(directory) }

    /// The persisted shape: the records plus the format they are written in, so a later
    /// change can migrate rather than guess.
    struct Document: Codable {
        var schemaVersion: SchemaVersion = .current
        var identities: [EnvironmentID: ProcessIdentity]
    }

    private static func load(from directory: Int32, path: String, decoder: JSONDecoder) throws -> [EnvironmentID: ProcessIdentity] {
        guard let data = try readIdentityFile(from: directory, path: path) else { return [:] }
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw ProcessIdentityStoreError.unreadable(path: path, reason: "the file is not a valid process record")
        }
        guard document.schemaVersion <= SchemaVersion.current else {
            throw ProcessIdentityStoreError.unreadable(path: path, reason: "the file was written by a newer Guesthouse")
        }
        // A record filed under one environment that describes another is not evidence of
        // anything: the whole document is refused rather than half-trusted.
        guard document.identities.allSatisfy({ $0.key == $0.value.environmentID && $0.value.isConsistent }) else {
            throw ProcessIdentityStoreError.unreadable(path: path, reason: "a record does not match the environment it is filed under")
        }
        return document.identities
    }

    /// The identity file's bytes, or `nil` when the directory holds no such entry.
    ///
    /// `O_NOFOLLOW` refuses a link planted in its place, including one whose target is missing:
    /// a path-existence check reports that as no file at all and would make damaged evidence
    /// look like a clean first run. `O_NONBLOCK` refuses a named pipe left here instead of
    /// waiting for a writer that never comes, which would hang the service.
    private static func readIdentityFile(from directory: Int32, path: String) throws -> Data? {
        let descriptor = openat(directory, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw ProcessIdentityStoreError.unreadable(path: path, reason: "the file is a symbolic link")
            default: throw ProcessIdentityStoreError.unreadable(path: path, reason: String(cString: strerror(errno)))
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProcessIdentityStoreError.unreadable(path: path, reason: "the file is not a regular file")
        }
        // A second link means these bytes also answer to a name outside the state directory,
        // and whoever holds that name can rewrite the ownership evidence.
        guard info.st_nlink == 1 else {
            throw ProcessIdentityStoreError.unreadable(path: path, reason: "the file has more than one name")
        }
        guard info.st_size <= maximumFileSize else {
            throw ProcessIdentityStoreError.unreadable(path: path, reason: "the file is too large to be a process record")
        }
        return try readAll(descriptor, path: path)
    }

    private static func readAll(_ descriptor: Int32, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= Int(maximumFileSize) else {
                    throw ProcessIdentityStoreError.unreadable(path: path, reason: "the file is too large to be a process record")
                }
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw ProcessIdentityStoreError.unreadable(path: path, reason: String(cString: strerror(errno)))
            }
        }
    }

    /// Removes leftovers from writes that were interrupted before their rename.
    static func removeStaleTemporaries(in directory: Int32) {
        // Cleanup takes the same exclusive folder lock `update` holds while it writes. The
        // per-temporary lock below is taken only after `openat` has already published the
        // name, so a store opening this folder in that window would find an unlocked file that
        // a writer is about to rename: unlinking it makes that rename fail after the VM it
        // records may already be running. Sharing the folder lock removes the window rather
        // than narrowing it (MVP-PLAN.md §4).
        guard lock(directory, LOCK_EX) else { return }
        defer { _ = lock(directory, LOCK_UN) }
        // `fdopendir` takes ownership of the descriptor it is handed, so it gets a duplicate:
        // the store keeps its own for every later operation.
        let duplicate = dup(directory)
        guard duplicate >= 0 else { return }
        guard let listing = fdopendir(duplicate) else {
            close(duplicate)
            return
        }
        defer { closedir(listing) }
        while let entry = readdir(listing) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard name.hasPrefix(".\(fileName).tmp-") else { continue }
            let candidate = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard candidate >= 0 else { continue }
            // A temporary another store still holds is that store's live write, not a leftover.
            // Unlinking it would make its rename fail on a healthy directory and leave a VM it
            // may already have launched with no ownership evidence at all. `StateStore` skips
            // locked temporaries the same way.
            if lock(candidate, LOCK_EX | LOCK_NB) { unlinkat(directory, name, 0) }
            close(candidate)
        }
    }

    /// `flock`, retrying the interruption a signal can cause. `false` means the lock is held
    /// by somebody else, or could not be taken at all.
    static func lock(_ descriptor: Int32, _ operation: Int32) -> Bool {
        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }

    public var all: [EnvironmentID: ProcessIdentity] { identities }

    public func identity(for environment: EnvironmentID) -> ProcessIdentity? { identities[environment] }

    /// Records the identity durably. Returns only after the file is on disk; memory changes
    /// only then, so a failed write never leaves the actor describing state the disk lacks.
    public func record(_ identity: ProcessIdentity) throws {
        // A record naming a VM the environment does not own would be persisted happily and
        // then make the whole document unreadable on the next start, stranding every surviving
        // VM. The write path enforces the same ownership invariant the load path does.
        guard identity.isConsistent else {
            throw ProcessIdentityStoreError.inconsistentIdentity(vmName: identity.vmName)
        }
        try update { staged in
            staged[identity.environmentID] = identity
            return true
        }
    }

    public func remove(_ environment: EnvironmentID) throws {
        try update { $0.removeValue(forKey: environment) != nil }
    }

    /// Applies one change to the document that is on disk, not to the snapshot this store read
    /// when it opened.
    ///
    /// Two stores can be open on one state folder — a reload while the first is still live, and
    /// the tests keep both — and each would otherwise stage its change onto its own
    /// initialization-time copy: the second write would replace the first store's record with a
    /// document that never contained it, and a VM that store launched would be left with no
    /// ownership evidence at all. So the read, the change and the write are held under one
    /// exclusive lock and the document is re-read inside it (MVP-PLAN.md §4).
    ///
    /// - Parameter change: mutates the refreshed document and answers whether it changed
    ///   anything; nothing is written when it did not.
    private func update(_ change: (inout [EnvironmentID: ProcessIdentity]) -> Bool) throws {
        // The folder's own descriptor is what is locked. A lock on the document would be a lock
        // on the inode `persist` is about to replace by rename, which excludes nobody; the
        // folder is the one object every writer here shares and never replaces.
        guard Self.lock(directory, LOCK_EX) else {
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "the state folder could not be locked")
        }
        defer { _ = Self.lock(directory, LOCK_UN) }
        // The refreshed document is only evidence about what the next launch will read if the
        // descriptor still names the configured folder. Adopting one read from a folder that
        // has been moved or removed would leave the store describing a document nothing will
        // open — including reporting a removal as done because that document was already gone.
        guard isStillTheConfiguredFolder() else {
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "the state folder is no longer at this path")
        }
        // A document that cannot be read now is refused rather than overwritten: whatever it
        // holds may be another store's evidence for a VM that is running.
        var staged = try Self.load(from: directory, path: url.path, decoder: decoder)
        guard change(&staged) else {
            identities = staged
            return
        }
        try persist(staged)
        identities = staged
    }

    private func persist(_ staged: [EnvironmentID: ProcessIdentity]) throws {
        let data: Data
        do {
            data = try encoder.encode(Document(identities: staged))
        } catch {
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "could not be encoded")
        }
        // The descriptor keeps naming the directory it opened even after that directory is
        // renamed, which is what stops a link planted at the path from redirecting a write. It
        // also means the write can land somewhere the next launch will not look: the service
        // opens the configured path, finds no record, and a VM this process launched loses its
        // ownership evidence. Reporting success for that would be claiming a durability the
        // record does not have, so it is refused instead (MVP-PLAN.md §3).
        guard isStillTheConfiguredFolder() else {
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "the state folder is no longer at this path")
        }
        let temporary = ".\(Self.fileName).tmp-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "the state folder is not writable")
        }
        // `openat` masks the mode it is given with the process umask, and the rename below
        // publishes this temporary as `processes.json` itself: a umask that clears the owner's
        // read bit leaves a record no later update and no next launch can reopen, while
        // `record` still returned successfully and a VM was launched on the strength of it.
        // `StateStore` normalizes every state file the same way (MVP-PLAN.md §3).
        var created = stat()
        guard fstat(descriptor, &created) == 0 else {
            close(descriptor)
            unlinkat(directory, temporary, 0)
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: String(cString: strerror(errno)))
        }
        if created.st_mode & 0o777 != 0o600, fchmod(descriptor, 0o600) != 0 {
            close(descriptor)
            unlinkat(directory, temporary, 0)
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "the file could not be made private")
        }
        // Held until the rename has happened, so a store opening this directory meanwhile can
        // tell this live write from a temporary an interrupted one left behind.
        guard Self.lock(descriptor, LOCK_EX) else {
            close(descriptor)
            unlinkat(directory, temporary, 0)
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "the state folder is not writable")
        }
        defer { close(descriptor) }
        do {
            try Self.writeAll(descriptor, data, path: url.path)
            try Self.fullySynchronize(descriptor, path: url.path)
        } catch {
            unlinkat(directory, temporary, 0)
            throw error
        }
        guard renameat(directory, temporary, directory, Self.fileName) == 0 else {
            let reason = String(cString: strerror(errno))
            unlinkat(directory, temporary, 0)
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: reason)
        }
        // The rename itself must be durable: synchronizing only the file leaves the directory
        // entry in the cache, so a power loss could lose the record that was just reported. A
        // synchronization that failed proves nothing about the disk, so it is never ignored.
        try Self.fullySynchronize(directory, path: url.path)
    }

    /// Whether the descriptor this store holds is still the folder it was given, compared by
    /// volume and inode so a folder renamed back and forth is judged by what it is.
    private nonisolated func isStillTheConfiguredFolder() -> Bool {
        var opened = stat()
        var configured = stat()
        guard fstat(directory, &opened) == 0, lstat(folder.path, &configured) == 0 else { return false }
        return opened.st_dev == configured.st_dev && opened.st_ino == configured.st_ino
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data, path: String) throws {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { raw in
                write(descriptor, raw.baseAddress! + written, data.count - written)
            }
            if count > 0 {
                written += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw ProcessIdentityStoreError.unwritable(path: path, reason: String(cString: strerror(errno)))
            }
        }
    }

    /// Forces bytes and directory entries onto permanent media. On macOS `fsync` can leave
    /// them in the drive's volatile cache, so an identity `recordLaunch` already reported as
    /// persisted could still vanish in a power loss; `F_FULLFSYNC` is the barrier that does
    /// not. A volume that does not implement it gets `fsync`, its strongest offer. `StateStore`
    /// does the same in the other package, which cannot be imported here.
    static func fullySynchronize(_ descriptor: Int32, path: String) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        switch errno {
        case ENOTSUP, ENOTTY, EINVAL, EPERM, ENODEV:
            guard fsync(descriptor) == 0 else {
                throw ProcessIdentityStoreError.unwritable(path: path, reason: String(cString: strerror(errno)))
            }
        default:
            throw ProcessIdentityStoreError.unwritable(path: path, reason: String(cString: strerror(errno)))
        }
    }
}

/// A process identity could not be persisted or read back. Either way a launched VM may be
/// running, so the outcome is unknown until the state is inspected.
public enum ProcessIdentityStoreError: Error, Hashable, Sendable, LocalizedError {
    case unwritable(path: String, reason: String)
    /// The record exists but could not be read or decoded; nothing it described can be
    /// trusted, and the service must not start VMs over ones it may have launched.
    case unreadable(path: String, reason: String)
    /// The identity offered for a write names a VM the environment does not own. Nothing was
    /// written, so the document on disk is still the one the next start can read.
    case inconsistentIdentity(vmName: String)

    public var userMessage: String {
        switch self {
        case .unwritable(let path, let reason):
            "Guesthouse could not record the development Mac's process in \(GuesthouseError.sanitize(path, limit: 200)) (\(GuesthouseError.sanitize(reason))). The virtual machine may still be running; Guesthouse will inspect the actual state. Free disk space or check the storage location in Settings if this persists."
        case .unreadable(let path, let reason):
            "Guesthouse could not read its record of launched development Macs at \(GuesthouseError.sanitize(path, limit: 200)) (\(GuesthouseError.sanitize(reason))). A development Mac started earlier may still be running. Guesthouse will inspect the actual state before starting anything; if the file is damaged, move it aside and check again."
        case .inconsistentIdentity(let vmName):
            "Guesthouse was asked to record the virtual machine \(GuesthouseError.sanitize(vmName, limit: 100)) for a development Mac that does not own it, so nothing was recorded. A virtual machine started for this development Mac may still be running; Guesthouse will inspect the actual state before starting anything else."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unwritable: [.inspectState, .freeDiskSpace, .openSettings, .cancel]
        case .unreadable: [.inspectState, .openSettings, .cancel]
        case .inconsistentIdentity: [.inspectState, .cancel]
        }
    }
    public var errorDescription: String? { userMessage }
}
