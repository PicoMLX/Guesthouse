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
    private let directoryBarrier: @Sendable (Int32, String) throws -> Void
    private let permissionBarrier: @Sendable (Int32, String) throws -> Void

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
        try self.init(rootURL: rootURL, migrator: migrator, directoryBarrier: Self.fullySynchronize)
    }

    /// Internal barriers let recovery tests replace files at the durability boundary.
    init(rootURL: URL, migrator: SnapshotMigrator = .standard,
         directoryBarrier: @escaping @Sendable (Int32, String) throws -> Void = StateStore.fullySynchronize,
         permissionBarrier: @escaping @Sendable (Int32, String) throws -> Void = StateStore.fullySynchronize) throws {
        self.rootURL = rootURL
        self.migrator = migrator
        self.directoryBarrier = directoryBarrier
        self.permissionBarrier = permissionBarrier
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
        // A decoded value may already have lost fields this build does not understand. Never
        // turn it into current state by replacing its version discriminator (MVP-PLAN.md §3).
        if snapshot.schemaVersion > migrator.current {
            throw StateStoreError.newerSchemaVersion(found: snapshot.schemaVersion, current: migrator.current)
        }
        guard snapshot.schemaVersion == migrator.current else {
            throw StateStoreError.inconsistentSnapshot(reason: "snapshot must be migrated to the current schema version before saving")
        }
        try snapshot.validate()
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            // A value the encoder refuses (a non-finite date, say) is an inconsistent snapshot
            // with a recovery path, never a raw `EncodingError`.
            throw StateStoreError.unencodable(name: Self.snapshotFileName)
        }

        // The file about to be replaced is inspected first. A rename repoints this directory
        // entry only, so a second name for the current snapshot would keep those bytes and the
        // permissions they carry, which is the thing `requirePrivateRegularFile` refuses
        // everywhere else (MVP-PLAN.md §3, "Local storage").
        if let existing = try openStateFile(Self.snapshotFileName, creating: false) {
            close(existing)
        }

        removeStaleTempFiles()
        let tempName = Self.tempPrefix + UUID().uuidString
        // The lock is what tells another store's `removeStaleTempFiles` that this temporary is a
        // live transaction rather than a leftover, so it is taken as part of creating the file
        // rather than afterwards: `O_EXLOCK` leaves no instant in which the temporary exists
        // unlocked, and cleanup running in such an instant would unlink the file this writer is
        // about to rename into place, failing the save on a perfectly healthy directory. A
        // filesystem that does not implement it falls back to locking the descriptor, which is
        // the narrowest window still available there.
        var descriptor = openat(directory, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK, 0o600)
        var locked = descriptor >= 0
        if descriptor < 0, errno == ENOTSUP {
            descriptor = openat(directory, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            locked = false
        }
        guard descriptor >= 0 else { throw StateStoreError.fileUnwritable(name: Self.snapshotFileName) }
        if !locked, !Self.lock(descriptor, LOCK_EX) {
            close(descriptor)
            unlinkat(directory, tempName, 0)
            throw StateStoreError.fileUnwritable(name: Self.snapshotFileName)
        }
        // `openat` masks the mode it is given with the process umask, and the rename below
        // publishes this temporary as the snapshot itself: a umask that clears the owner's read
        // bit would put an `environments.json` in place that the next launch cannot open, and
        // `saveSnapshot` would still have returned successfully. The check every other state
        // file passes puts the mode back and drops an access control list the directory may
        // have handed the new file (MVP-PLAN.md §3, "Local storage"). It runs under the lock,
        // not in front of it, for the reason above.
        do {
            try Self.requirePrivateRegularFile(descriptor, name: Self.snapshotFileName, synchronize: permissionBarrier)
        } catch {
            close(descriptor)
            unlinkat(directory, tempName, 0)
            throw error
        }
        defer { close(descriptor) }
        do {
            try Self.writeAll(descriptor, data, name: Self.snapshotFileName)
            try Self.fullySynchronize(descriptor, name: Self.snapshotFileName)
        } catch {
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
        // The record before this one is complete but unterminated, so its newline is written
        // here; without it the two lines would fuse into one unreadable record.
        if state.unterminatedRecord {
            line.insert(0x0A, at: line.startIndex)
        }
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
            // Durable, but only in the file this descriptor names. If the entry now names some
            // other file, the next launch reads that one and never sees this operation, which is
            // exactly the blind retry the journal exists to prevent.
            try Self.requireEntryStillNames(descriptor, in: directory, name: Self.journalFileName)
            if !journalEntryIsDurable {
                try synchronizeDirectory()
            }
            // The directory barrier can outlive a concurrent restore or rename. Recheck both
            // names after the final barrier, before reporting that this operation can start.
            try requireAnchoredDirectoryIsCurrent()
            try Self.requireEntryStillNames(descriptor, in: directory, name: Self.journalFileName)
            journalEntryIsDurable = true
        } catch {
            // The file no longer matches what was read, so nothing about it is remembered.
            journal = JournalState()
            journalEntryIsDurable = false
            throw error
        }
        // The record now ends the file; any torn tail was truncated above.
        journal.adopt(record, bytes: line.count)
        journal.truncatedTail = false
        journal.unterminatedRecord = false
        // The write moved the file's timestamps, so the remembered version is taken again:
        // otherwise the next refresh would read the whole journal back as if someone else had
        // rewritten it.
        var written = stat()
        journal.file = fstat(descriptor, &written) == 0 ? FileVersion(written) : nil
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
        let version = FileVersion(info)
        // A different file, one rewritten in place, or one that lost bytes, invalidates
        // everything read before it.
        if state.file != version || off_t(state.byteCount) > info.st_size {
            if state.file?.identity != version.identity {
                // A file this store never synchronized the entry of. An earlier one's entry
                // says nothing about this one: the replacement may have arrived through an
                // unsynchronized restore or rename, and a power loss would take it along with
                // the `started` record `begin` has already reported.
                journalEntryIsDurable = false
            }
            state = JournalState()
            state.file = version
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
        state.unterminatedRecord = false
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var unterminated: Data.SubSequence?
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
        } else if !lines.isEmpty {
            unterminated = lines.removeLast()
        }
        for line in lines {
            // Every valid line contributes exactly one record, so this is its number in the
            // file even though only the new bytes were read.
            let number = state.records.count + 1
            // An empty line between records means bytes were lost; it is never skipped.
            guard !line.isEmpty, let record = try decode(line, number: number), accepts(record, in: state) else {
                throw StateStoreError.corruptJournal(line: number)
            }
            state.adopt(record, bytes: line.count + 1)
        }
        guard let unterminated else { return }
        // A complete record that lost only its newline — a restore or a repair can leave one —
        // is a record, not a torn write. Dropping it would hide a `started` mutation and let the
        // next one run on that environment without inspecting anything.
        guard let record = try decode(unterminated, number: state.records.count + 1), accepts(record, in: state) else {
            state.truncatedTail = true
            return
        }
        state.adopt(record, bytes: unterminated.count)
        state.unterminatedRecord = true
    }

    /// Decodes one journal line. A line this build cannot read because it was written in a newer
    /// record format is told apart from a damaged one: the fix is an update, not an inspection.
    private func decode(_ line: Data.SubSequence, number: Int) throws -> JournalRecord? {
        if let declared = try? decoder.decode(RecordFormat.self, from: line), !JournalRecord.canRead(declared.format) {
            // Only a number above this build's is a newer Guesthouse's. Readable formats start
            // at 1, so zero or a negative one names no release at all: it is damage, and the
            // update the other error asks for cannot repair it, while inspecting the actual
            // state can.
            guard declared.format > JournalRecord.currentFormat else {
                throw StateStoreError.corruptJournal(line: number)
            }
            throw StateStoreError.unsupportedJournalFormat(line: number, format: declared.format)
        }
        return try? decoder.decode(JournalRecord.self, from: line)
    }

    /// Just the format of a line, read before the record itself so an unreadable format is
    /// reported as one rather than as damage.
    private struct RecordFormat: Decodable {
        let format: Int
    }

    /// Whether replay may adopt `record`. The journal can also be written by a restore or a
    /// repair tool, so replay applies the rules `append` applies rather than trusting the file.
    private func accepts(_ record: JournalRecord, in state: JournalState) -> Bool {
        guard record.isSelfConsistent else { return false }
        guard let identity = state.identities[record.id] else {
            // A second start for one environment is a state the store itself refuses to create;
            // adopting both would leave recovery with two mutations and no way to tell which of
            // them to inspect.
            return record.outcome == .started
                && !state.inFlight.values.contains { $0.environmentID == record.environmentID }
        }
        return record.outcome != .started
            && !state.settled.contains(record.id)
            && identity.environment == record.environmentID
            && identity.operation == record.operation
    }

    private func validateIdentity(of record: JournalRecord, against state: JournalState) throws {
        // A record that disagrees with itself — naming another operation, another development
        // Mac, or another stage than the one it belongs to — would leave recovery with two
        // answers to the question of what to inspect.
        guard record.isSelfConsistent else { throw StateStoreError.inconsistentRecord(record.id) }
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
        try requireAnchoredDirectoryIsCurrent()
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
            try Self.requirePrivateRegularFile(descriptor, name: name, synchronize: permissionBarrier)
        } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    /// The directory this store anchored at startup must still be the one `rootURL` names. If it
    /// was renamed, removed, or replaced, every write below the cached descriptor lands in a
    /// directory nobody will look in again: `begin` would report a `started` record durable while
    /// the next launch, opening the directory now at `rootURL`, finds no record of the mutation.
    private func requireAnchoredDirectoryIsCurrent() throws {
        var anchored = stat()
        var current = stat()
        guard fstat(directory, &anchored) == 0 else {
            throw StateStoreError.insecureDirectory(reason: "cannot be read")
        }
        guard lstat(rootURL.path, &current) == 0, FileIdentity(current) == FileIdentity(anchored) else {
            throw StateStoreError.insecureDirectory(reason: "the folder was renamed, removed, or replaced while Guesthouse was using it")
        }
    }

    /// Confirms the directory entry still names the file this descriptor is open on.
    static func requireEntryStillNames(_ descriptor: Int32, in directory: Int32, name: String) throws {
        var opened = stat()
        var entry = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(opened) == FileIdentity(entry)
        else {
            throw StateStoreError.fileUnwritable(name: name)
        }
    }

    private func readStateFile(_ name: String) throws -> Data? {
        guard let descriptor = try openStateFile(name, creating: false) else { return nil }
        defer { close(descriptor) }
        return try Self.readAll(descriptor, from: 0, name: name)
    }

    static func requirePrivateRegularFile(
        _ descriptor: Int32, name: String,
        synchronize: (Int32, String) throws -> Void = fullySynchronize
    ) throws {
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
        try removeExtendedACL(descriptor, name: name, synchronize: synchronize)
    }

    /// Removes an inherited or restored access control list. A mode of `0600` says nothing
    /// about an ACL, and `fchmod` does not clear one, so another principal could still read or
    /// write a file the store considers private.
    static func removeExtendedACL(
        _ descriptor: Int32, name: String,
        synchronize: (Int32, String) throws -> Void = fullySynchronize
    ) throws {
        errno = 0
        guard let existing = acl_get_fd(descriptor) else {
            // A file with no list at all is reported as a failure with `ENOENT`. Any other
            // reason means the list could not be read, and an unreadable list is not an absent
            // one: the store cannot establish that no other principal has access, so it refuses
            // the file rather than assuming the answer it wants (MVP-PLAN.md §3).
            guard errno == ENOENT else {
                throw StateStoreError.insecureDirectory(reason: "\(name) access control cannot be read")
            }
            // An earlier attempt may have repaired the mode or removed this list and then
            // failed its barrier. Visible private metadata is not proof of durable privacy.
            try synchronize(descriptor, name)
            return
        }
        // Whatever the list holds is replaced rather than inspected. Telling "this list has no
        // entries" apart from "these entries could not be read" is exactly the distinction that
        // must not be guessed, and an empty list is the right answer to both.
        acl_free(UnsafeMutableRawPointer(existing))
        guard let empty = acl_init(0) else {
            throw StateStoreError.insecureDirectory(reason: "\(name) cannot be made private")
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        guard acl_set_fd(descriptor, empty) == 0 else {
            throw StateStoreError.insecureDirectory(reason: "\(name) cannot be made private")
        }
        // Read-only snapshot loads and journal replays have no later write to flush these
        // repairs. This also persists the mode that the file or directory caller set first.
        try synchronize(descriptor, name)
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
        try directoryBarrier(directory, rootURL.lastPathComponent)
        directorySynchronizations += 1
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw StateStoreError.insecureDirectory(reason: "cannot be opened") }
        defer { close(descriptor) }
        try fullySynchronize(descriptor, name: url.lastPathComponent)
    }

    static func prepareDirectory(_ url: URL, synchronize: (URL) throws -> Void = synchronizeDirectory(at:)) throws -> Int32 {
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
            // Visible ancestors can be leftovers from a process killed after mkdir, before
            // any barrier or rollback. Their existence is not proof of durability. Resync on
            // every initialization, including a new leaf under existing unfinished ancestors.
            // Include the supplied path and its physical target: a symlinked ancestor needs
            // its own entry persisted as well as the directories reached through it.
            guard let physicalPath = realpath(url.path, nil) else {
                throw StateStoreError.insecureDirectory(reason: "cannot resolve directory ancestry")
            }
            defer { free(physicalPath) }
            let physicalURL = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
            var synchronized: Set<String> = []
            for location in [physicalURL, url] {
                var parents: [URL] = []
                var child = URL(fileURLWithPath: location.path, isDirectory: true)
                while child.path != "/" {
                    let parent = child.deletingLastPathComponent()
                    guard parent.path != child.path else { break }
                    parents.append(parent)
                    child = parent
                }
                for parent in parents.reversed() where synchronized.insert(parent.path).inserted {
                    try synchronize(parent)
                }
            }
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
        // One level at a time rather than `withIntermediateDirectories`, which is content with
        // a directory that already exists: what the survey found missing and what this attempt
        // actually made are two different lists as soon as a second initialization is creating
        // the same root. Only what this one made can be rolled back, or a failure here would
        // take the other store's journal with it.
        var created: [URL] = []
        for directory in directoriesToCreate(for: url).reversed() {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                created.append(directory)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                // A chain this attempt cannot finish is removed again, for the same reason
                // `makeCreatedDirectoriesDurable` removes one it cannot make durable: leaving
                // the ancestors behind makes the next attempt find them present, create
                // nothing, and synchronize nothing, so the store comes up anchored on entries a
                // power loss can still take — with the journal a `begin` has already reported
                // durable inside them. Deepest first, and `rmdir` only, so a directory that is
                // not this attempt's own and empty stays where it is.
                for orphan in created.reversed() { rmdir(orphan.path) }
                throw StateStoreError.fileUnwritable(name: url.lastPathComponent)
            }
        }
        // Deepest first, the order the rollback and the synchronization both walk.
        try makeCreatedDirectoriesDurable(created.reversed(), synchronize: synchronizeDirectory(at:))
    }

    /// Makes every new entry durable in its own parent, not just the deepest one: otherwise a
    /// power loss could take an unsynchronized ancestor and with it a journal whose `begin` has
    /// already returned, inviting a blind retry after the reboot.
    ///
    /// A chain that could not be made durable is removed again rather than left behind. Leaving
    /// it would make the next attempt find the directories present, create nothing, and
    /// synchronize nothing, so the store would come up anchored on an ancestry that a power loss
    /// can still take away.
    ///
    /// `created` holds only what the caller actually made, deepest first, and each entry is
    /// removed only while it is empty. Between them those two rules keep the rollback to this
    /// attempt's own work: a directory another initialization created, or one it has already put
    /// a journal or a snapshot in, is not this attempt's to erase, and erasing it would destroy
    /// the operation record that store needs to avoid a blind retry.
    static func makeCreatedDirectoriesDurable(_ created: [URL], synchronize: (URL) throws -> Void) throws {
        for directory in created.reversed() {
            do {
                try synchronize(directory.deletingLastPathComponent())
            } catch {
                // Deepest first, so a parent this attempt made is empty by the time it is
                // reached and a parent holding anything else stays.
                for orphan in created {
                    rmdir(orphan.path)
                }
                throw error
            }
        }
    }

    private func removeStaleTempFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootURL.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) {
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            // A temporary another writer still holds is that writer's live snapshot, not a
            // leftover. Unlinking it would make its rename fail on a perfectly healthy
            // directory, reported to the user as a storage failure.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
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

/// The identity plus the timestamps that move when the file's bytes are rewritten. A restore or
/// a repair that puts different records into the same inode, at the same length or a greater
/// one, is otherwise indistinguishable from the file the remembered replay was read from, and
/// the store would authorize a second mutation against a journal it has not actually read.
private struct FileVersion: Hashable {
    let identity: FileIdentity
    let modified: Int64
    let modifiedNanoseconds: Int
    let changed: Int64
    let changedNanoseconds: Int

    init(_ info: stat) {
        identity = FileIdentity(info)
        modified = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changed = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

/// The replay of the journal bytes read so far.
private struct JournalState {
    var file: FileVersion?
    /// Bytes of complete, validated lines, including the final record's missing newline when
    /// `unterminatedRecord` is set. Anything past this is a torn tail.
    var byteCount = 0
    var truncatedTail = false
    /// The last record is complete but its newline is missing, so the next append writes one
    /// before its own line rather than fusing the two.
    var unterminatedRecord = false
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
