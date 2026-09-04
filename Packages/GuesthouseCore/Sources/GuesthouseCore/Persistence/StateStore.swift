import Foundation

/// Owns the on-disk state of the app: a versioned JSON snapshot and an append-only journal.
///
/// - The snapshot is replaced atomically (temp file, full sync, rename, directory sync), so a
///   crash mid-write leaves the previous snapshot intact and a completed save survives power
///   loss.
/// - The journal is newline-delimited JSON, appended and synced per record. `begin` returns
///   an `OperationID` only after its `started` record and the directory entry are durable, so
///   an operation can never be running without the journal knowing.
/// - Every file operation runs relative to a descriptor for the state directory, opened once
///   after the directory itself was verified. A component of the path replaced afterwards
///   cannot redirect a later write out of the state hierarchy.
/// - The directory is created `0700` and every file `0600`, extended ACLs are removed, links
///   are never followed, and a file with a second name is refused (MVP-PLAN.md §3,
///   "Local storage").
/// - Dates are stored as seconds since the reference date, the representation `Date` itself
///   uses, so a save and load round trip is exact.
///
/// One actor per directory is the design (MVP-PLAN.md §3: "Avoid two independent writers to
/// the same environment state"), but a second writer is not left to corrupt the journal: the
/// read, validate, truncate and append sequence is held under an exclusive lock on the file.
public actor StateStore {
    public static let snapshotFileName = "environments.json"
    public static let journalFileName = "journal.ndjson"
    static let tempPrefix = ".environments.json.tmp-"

    public let rootURL: URL
    /// The verified state directory. Every open, rename and unlink below is relative to it.
    private let directory: Int32
    private let migrator: SnapshotMigrator
    private let encoder: JSONEncoder
    private let lineEncoder: JSONEncoder
    private let decoder: JSONDecoder

    /// What replay has already learned, and how far into the journal it is valid.
    private var journal = JournalState()
    /// Whether this process has made the journal's directory entry durable. An earlier process
    /// may have created the file and then died before synchronizing it, so the file already
    /// existing is not proof that its entry survives a power loss.
    private var journalEntryIsDurable = false

    /// Journal bytes actually read from disk. The tests use it to hold the store to reading
    /// only what is new on an append instead of the whole history.
    private(set) var journalBytesRead = 0
    /// Completed directory synchronizations, for the same reason.
    private(set) var directorySynchronizations = 0

    public init(rootURL: URL, migrator: SnapshotMigrator = .standard) throws {
        self.rootURL = rootURL
        self.migrator = migrator
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        directory = try Self.prepareDirectory(rootURL)
    }

    deinit { close(directory) }

    // MARK: - Snapshot

    public var snapshotURL: URL { rootURL.appending(path: Self.snapshotFileName) }
    public var journalURL: URL { rootURL.appending(path: Self.journalFileName) }

    /// The saved snapshot, migrated to the current schema, or `.empty` if none exists.
    public func loadSnapshot() throws -> EnvironmentsSnapshot {
        guard let raw = try readStateFile(Self.snapshotFileName) else { return .empty }
        let (data, _) = try migrator.migrate(raw)
        do {
            return try decoder.decode(EnvironmentsSnapshot.self, from: data)
        } catch {
            throw StateStoreError.corruptSnapshot
        }
    }

    /// Replaces the snapshot atomically. Stale temp files from an earlier crash are removed.
    public func saveSnapshot(_ snapshot: EnvironmentsSnapshot) throws {
        try snapshot.validate()
        var stamped = snapshot
        stamped.schemaVersion = migrator.current
        let data: Data
        do {
            data = try encoder.encode(stamped)
        } catch {
            // A value the encoder refuses (a non-finite date, say) is an inconsistent snapshot
            // with a recovery path, never a raw `EncodingError`.
            throw StateStoreError.unencodable(name: Self.snapshotFileName)
        }

        removeStaleTempFiles()
        let tempName = Self.tempPrefix + UUID().uuidString
        let descriptor = openat(directory, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StateStoreError.fileUnwritable(name: Self.snapshotFileName) }
        do {
            try Self.writeAll(descriptor, data, name: Self.snapshotFileName)
            try Self.fullySynchronize(descriptor, name: Self.snapshotFileName)
            close(descriptor)
        } catch {
            close(descriptor)
            unlinkat(directory, tempName, 0)
            throw error
        }
        guard renameat(directory, tempName, directory, Self.snapshotFileName) == 0 else {
            unlinkat(directory, tempName, 0)
            throw StateStoreError.fileUnwritable(name: Self.snapshotFileName)
        }
        try synchronizeDirectory()
    }

    // MARK: - Journal

    /// Appends a `started` record and returns its id only once the record is on disk.
    public func begin(_ operation: JournalOperation, for environmentID: EnvironmentID, at timestamp: Date = Date()) throws -> OperationID {
        let id = OperationID()
        try append(JournalRecord(id: id, environmentID: environmentID, operation: operation, timestamp: timestamp, outcome: .started))
        return id
    }

    /// Appends one record and makes it durable before returning.
    ///
    /// A follow-up record must belong to an operation the journal has started, with the same
    /// environment and operation, and that has not already settled; a torn final line left by
    /// an earlier crash is truncated first, so it can never fuse with this record.
    public func append(_ record: JournalRecord) throws {
        var line: Data
        do {
            line = try lineEncoder.encode(record)
        } catch {
            throw StateStoreError.unencodable(name: Self.journalFileName)
        }
        line.append(0x0A)

        guard let descriptor = try openStateFile(Self.journalFileName, creating: true) else {
            throw StateStoreError.fileUnwritable(name: Self.journalFileName)
        }
        defer { close(descriptor) }
        // Held across read, validation, truncation and append: another writer that seeked to
        // the same end offset would otherwise overwrite this record, or ours theirs, and both
        // `begin` calls would return with only one record on disk.
        guard Self.lock(descriptor, LOCK_EX) else { throw StateStoreError.fileUnwritable(name: Self.journalFileName) }

        let state = try refreshJournal(descriptor)
        try validateIdentity(of: record, against: state)
        do {
            if state.truncatedTail {
                guard ftruncate(descriptor, off_t(state.byteCount)) == 0 else {
                    throw StateStoreError.fileUnwritable(name: Self.journalFileName)
                }
            }
            guard lseek(descriptor, 0, SEEK_END) >= 0 else {
                throw StateStoreError.fileUnwritable(name: Self.journalFileName)
            }
            try Self.writeAll(descriptor, line, name: Self.journalFileName)
            try Self.fullySynchronize(descriptor, name: Self.journalFileName)
        } catch {
            // The file no longer matches what was read, so nothing about it is remembered.
            journal = JournalState()
            throw error
        }
        if !journalEntryIsDurable {
            try synchronizeDirectory()
            journalEntryIsDurable = true
        }
        // The record now ends the file; any torn tail was truncated above.
        journal.adopt(record, bytes: line.count)
        journal.truncatedTail = false
    }

    /// Reads every record and lists the operations that never reached a terminal outcome.
    public func replay() throws -> JournalReplay {
        guard let descriptor = try openStateFile(Self.journalFileName, creating: false) else {
            return JournalReplay(records: [], inFlight: [:], truncatedTail: false)
        }
        defer { close(descriptor) }
        guard Self.lock(descriptor, LOCK_SH) else { throw StateStoreError.fileUnreadable(name: Self.journalFileName) }
        let state = try refreshJournal(descriptor)
        return JournalReplay(records: state.records, inFlight: state.inFlight, truncatedTail: state.truncatedTail)
    }

    /// Brings the remembered replay state up to date with the file, reading only the bytes
    /// added since the last time. Rescanning the whole history on every record would make
    /// writing the journal cost time quadratic in its length, and it only ever grows.
    private func refreshJournal(_ descriptor: Int32) throws -> JournalState {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw StateStoreError.fileUnreadable(name: Self.journalFileName) }
        var state = journal
        // A different file, or one that lost bytes, invalidates everything read before it.
        if state.file != FileIdentity(info) || off_t(state.byteCount) > info.st_size {
            state = JournalState()
            state.file = FileIdentity(info)
        }
        if off_t(state.byteCount) == info.st_size {
            state.truncatedTail = false
        } else {
            let fresh = try Self.readAll(descriptor, from: off_t(state.byteCount), name: Self.journalFileName)
            journalBytesRead += fresh.count
            try fold(fresh, into: &state)
        }
        journal = state
        return state
    }

    /// Folds newly read bytes into the replay state, rejecting the whole journal at the first
    /// line that cannot be trusted.
    private func fold(_ data: Data, into state: inout JournalState) throws {
        state.truncatedTail = false
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
        } else if !lines.isEmpty {
            state.truncatedTail = true
            lines.removeLast()
        }
        for line in lines {
            // Every valid line contributes exactly one record, so this is its number in the
            // file even though only the new bytes were read.
            let number = state.records.count + 1
            // An empty line between records means bytes were lost; it is never skipped.
            guard !line.isEmpty, let record = try? decoder.decode(JournalRecord.self, from: line) else {
                throw StateStoreError.corruptJournal(line: number)
            }
            if let identity = state.identities[record.id] {
                guard record.outcome != .started,
                      !state.settled.contains(record.id),
                      identity.environment == record.environmentID,
                      identity.operation == record.operation
                else {
                    throw StateStoreError.corruptJournal(line: number)
                }
            } else {
                guard record.outcome == .started else { throw StateStoreError.corruptJournal(line: number) }
            }
            state.adopt(record, bytes: line.count + 1)
        }
    }

    private func validateIdentity(of record: JournalRecord, against state: JournalState) throws {
        // An unknown-outcome failure names the operation it belongs to. A record naming another
        // one would leave recovery with two identities for a single mutation.
        if case .failed(.operationOutcomeUnknown(let reported)) = record.outcome, reported != record.id {
            throw StateStoreError.inconsistentRecord(record.id)
        }
        switch (record.outcome, state.identities[record.id]) {
        case (.started, nil):
            // A new mutation on an environment whose earlier one has no known outcome would be
            // a blind retry; the earlier one must be reconciled first.
            if let unresolved = state.inFlight.values.first(where: { $0.environmentID == record.environmentID }) {
                throw StateStoreError.operationUnresolved(unresolved.id)
            }
        case (.started, .some):
            throw StateStoreError.inconsistentRecord(record.id)
        case (_, nil):
            throw StateStoreError.inconsistentRecord(record.id)
        case (_, .some(let identity)):
            // A late checkpoint or "unknown" after a durable result would put a settled
            // operation back in flight and block its environment for no reason.
            guard !state.settled.contains(record.id) else { throw StateStoreError.inconsistentRecord(record.id) }
            guard identity.environment == record.environmentID, identity.operation == record.operation else {
                throw StateStoreError.inconsistentRecord(record.id)
            }
        }
    }

    // MARK: - Files

    /// Opens a state file relative to the verified directory and requires it to be a private,
    /// singly linked regular file. `nil` when it does not exist and is not being created.
    ///
    /// `O_NONBLOCK` keeps a named pipe left in place of a state file from blocking the store
    /// until someone opens the other end; `fstat` then refuses it like any other non-file.
    private func openStateFile(_ name: String, creating: Bool) throws -> Int32? {
        let flags = (creating ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var descriptor = openat(directory, name, flags, 0o600)
        // Two writers that reach a state file which does not exist yet can both be told the
        // name is missing while the other one creates it. That is transient, so the create is
        // retried instead of being reported as a storage failure.
        var remainingAttempts = 4
        while descriptor < 0, creating, errno == ENOENT, remainingAttempts > 0 {
            remainingAttempts -= 1
            descriptor = openat(directory, name, flags, 0o600)
        }
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT where !creating: return nil
            case ELOOP: throw StateStoreError.insecureDirectory(reason: "\(name) is a symbolic link")
            default:
                throw creating
                    ? StateStoreError.fileUnwritable(name: name)
                    : StateStoreError.insecureDirectory(reason: "\(name) cannot be opened")
            }
        }
        do {
            try Self.requirePrivateRegularFile(descriptor, name: name)
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private func readStateFile(_ name: String) throws -> Data? {
        guard let descriptor = try openStateFile(name, creating: false) else { return nil }
        defer { close(descriptor) }
        return try Self.readAll(descriptor, from: 0, name: name)
    }

    private static func requirePrivateRegularFile(_ descriptor: Int32, name: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw StateStoreError.insecureDirectory(reason: "\(name) is not a regular file")
        }
        // A second link means these bytes and this mode also belong to a file outside the
        // state directory, which a restore or a manual replacement can leave behind.
        guard info.st_nlink == 1 else {
            throw StateStoreError.insecureDirectory(reason: "\(name) has more than one name")
        }
        if info.st_mode & 0o777 != 0o600 {
            guard fchmod(descriptor, 0o600) == 0 else {
                throw StateStoreError.insecureDirectory(reason: "\(name) cannot be made private")
            }
        }
        try removeExtendedACL(descriptor, name: name)
    }

    /// Removes an inherited or restored access control list. A mode of `0600` says nothing
    /// about an ACL, and `fchmod` does not clear one, so another principal could still read or
    /// write a file the store considers private.
    private static func removeExtendedACL(_ descriptor: Int32, name: String) throws {
        guard let existing = acl_get_fd(descriptor) else { return }
        var entry: acl_entry_t?
        let hasEntry = acl_get_entry(existing, ACL_FIRST_ENTRY.rawValue, &entry) == 0
        acl_free(UnsafeMutableRawPointer(existing))
        guard hasEntry else { return }
        guard let empty = acl_init(0) else {
            throw StateStoreError.insecureDirectory(reason: "\(name) cannot be made private")
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        guard acl_set_fd(descriptor, empty) == 0 else {
            throw StateStoreError.insecureDirectory(reason: "\(name) cannot be made private")
        }
    }

    private static func readAll(_ descriptor: Int32, from offset: off_t, name: String) throws -> Data {
        guard lseek(descriptor, offset, SEEK_SET) >= 0 else { throw StateStoreError.fileUnreadable(name: name) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                // An I/O error while reading saved state is a storage problem the user can act
                // on, never a raw Foundation error.
                throw StateStoreError.fileUnreadable(name: name)
            }
        }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data, name: String) throws {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { raw in
                write(descriptor, raw.baseAddress! + written, data.count - written)
            }
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw StateStoreError.fileUnwritable(name: name)
            }
        }
    }

    /// Forces the bytes onto permanent media. `fsync` alone leaves them in the drive's
    /// volatile cache on macOS, so a record `begin` already reported could still vanish in a
    /// power loss; `F_FULLFSYNC` is the barrier that does not. A volume that does not
    /// implement it (some network and virtual filesystems) gets `fsync`, its strongest offer.
    static func fullySynchronize(_ descriptor: Int32, name: String) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        switch errno {
        case ENOTSUP, ENOTTY, EINVAL, EPERM, ENODEV:
            guard fsync(descriptor) == 0 else { throw StateStoreError.fileUnwritable(name: name) }
        default:
            throw StateStoreError.fileUnwritable(name: name)
        }
    }

    private static func lock(_ descriptor: Int32, _ operation: Int32) -> Bool {
        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }

    /// Makes directory entries (a rename, a new file) durable.
    private func synchronizeDirectory() throws {
        try Self.fullySynchronize(directory, name: rootURL.lastPathComponent)
        directorySynchronizations += 1
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw StateStoreError.insecureDirectory(reason: "cannot be opened") }
        defer { close(descriptor) }
        try fullySynchronize(descriptor, name: url.lastPathComponent)
    }

    private static func prepareDirectory(_ url: URL) throws -> Int32 {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) != S_IFLNK else { throw StateStoreError.insecureDirectory(reason: "symbolic link") }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw StateStoreError.insecureDirectory(reason: "not a directory") }
        } else {
            try createDirectory(url)
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StateStoreError.insecureDirectory(reason: "cannot be opened") }
        do {
            guard fchmod(descriptor, 0o700) == 0 else {
                throw StateStoreError.insecureDirectory(reason: "cannot be made private")
            }
            try removeExtendedACL(descriptor, name: url.lastPathComponent)
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    /// The components of `url` that do not exist yet, deepest first.
    static func directoriesToCreate(for url: URL) -> [URL] {
        var missing: [URL] = []
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            missing.append(candidate)
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return missing
    }

    private static func createDirectory(_ url: URL) throws {
        let missing = directoriesToCreate(for: url)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw StateStoreError.fileUnwritable(name: url.lastPathComponent)
        }
        // Every new entry is made durable in its own parent, not just the deepest one:
        // otherwise a power loss could take an unsynchronized ancestor and with it a journal
        // whose `begin` has already returned, inviting a blind retry after the reboot.
        for created in missing.reversed() {
            try synchronizeDirectory(at: created.deletingLastPathComponent())
        }
    }

    private func removeStaleTempFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootURL.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) {
            unlinkat(directory, name, 0)
        }
    }
}

/// Which file the remembered journal state was read from, so a replaced one is not mistaken
/// for a longer version of the same file.
private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

/// The replay of the journal bytes read so far.
private struct JournalState {
    var file: FileIdentity?
    /// Bytes of complete, validated lines. Anything past this is a torn tail.
    var byteCount = 0
    var truncatedTail = false
    var records: [JournalRecord] = []
    var inFlight: [OperationID: JournalRecord] = [:]
    var identities: [OperationID: (environment: EnvironmentID, operation: JournalOperation)] = [:]
    /// Operations with a durable result. Nothing may be recorded against them again.
    var settled: Set<OperationID> = []

    mutating func adopt(_ record: JournalRecord, bytes: Int) {
        byteCount += bytes
        records.append(record)
        identities[record.id] = (record.environmentID, record.operation)
        if record.leavesInFlight {
            inFlight[record.id] = record
        } else {
            inFlight.removeValue(forKey: record.id)
            settled.insert(record.id)
        }
    }
}
