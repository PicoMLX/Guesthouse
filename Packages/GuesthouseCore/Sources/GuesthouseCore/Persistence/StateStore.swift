import Foundation

/// Owns the on-disk state of the app: a versioned JSON snapshot and an append-only journal.
///
/// - The snapshot is replaced atomically (temp file, fsync, rename, directory fsync), so a
///   crash mid-write leaves the previous snapshot intact and a completed save survives power
///   loss.
/// - The journal is newline-delimited JSON, appended and fsynced per record. `begin` returns
///   an `OperationID` only after its `started` record and, for a new file, the directory entry
///   are durable, so an operation can never be running without the journal knowing.
/// - The directory is created `0700` and every file `0600`; an existing file with a wider
///   mode is narrowed before use, and symbolic links are never followed (MVP-PLAN.md §3,
///   "Local storage").
/// - Dates are stored as seconds since the reference date, the representation `Date` itself
///   uses, so a save and load round trip is exact.
///
/// One actor per directory. Two writers to the same directory are a design error
/// (MVP-PLAN.md §3: "Avoid two independent writers to the same environment state").
public actor StateStore {
    public static let snapshotFileName = "environments.json"
    public static let journalFileName = "journal.ndjson"
    static let tempPrefix = ".environments.json.tmp-"

    public let rootURL: URL
    private let migrator: SnapshotMigrator
    private let encoder: JSONEncoder
    private let lineEncoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL, migrator: SnapshotMigrator = .standard) throws {
        self.rootURL = rootURL
        self.migrator = migrator
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        try Self.prepareDirectory(rootURL)
    }

    // MARK: - Snapshot

    public var snapshotURL: URL { rootURL.appending(path: Self.snapshotFileName) }
    public var journalURL: URL { rootURL.appending(path: Self.journalFileName) }

    /// The saved snapshot, migrated to the current schema, or `.empty` if none exists.
    public func loadSnapshot() throws -> EnvironmentsSnapshot {
        guard let raw = try Self.readPrivateFile(at: snapshotURL) else { return .empty }
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
        let data = try encoder.encode(stamped)

        removeStaleTempFiles()
        let tempURL = rootURL.appending(path: Self.tempPrefix + UUID().uuidString)
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StateStoreError.fileUnwritable(name: Self.snapshotFileName)
        }
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw StateStoreError.fileUnwritable(name: Self.snapshotFileName)
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            // A full volume or a failed sync is a storage problem with a recovery path, never
            // a raw Foundation error.
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw StateStoreError.fileUnwritable(name: Self.snapshotFileName)
        }
        guard rename(tempURL.path, snapshotURL.path) == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw StateStoreError.fileUnwritable(name: Self.snapshotFileName)
        }
        try Self.synchronizeDirectory(rootURL)
    }

    // MARK: - Journal

    /// Appends a `started` record and returns its id only once the record is on disk.
    public func begin(_ operation: JournalOperation, for environmentID: EnvironmentID, at timestamp: Date = Date()) throws -> OperationID {
        let id = OperationID()
        try append(JournalRecord(id: id, environmentID: environmentID, operation: operation, timestamp: timestamp, outcome: .started))
        return id
    }

    /// Appends one record and fsyncs before returning.
    ///
    /// A follow-up record must belong to an operation the journal has started, with the same
    /// environment and operation; a torn final line left by an earlier crash is truncated
    /// first, so it can never fuse with this record.
    public func append(_ record: JournalRecord) throws {
        try validateIdentity(of: record)
        var line = try lineEncoder.encode(record)
        line.append(0x0A)

        let existed = FileManager.default.fileExists(atPath: journalURL.path)
        let descriptor = open(journalURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw errno == ELOOP
                ? StateStoreError.insecureDirectory(reason: "\(Self.journalFileName) is a symbolic link")
                : StateStoreError.fileUnwritable(name: Self.journalFileName)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try Self.requireRegularPrivateFile(descriptor, name: Self.journalFileName)

        if let existing = try handle.readToEnd(), let last = existing.last, last != 0x0A {
            let keep = existing.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            guard ftruncate(descriptor, off_t(keep)) == 0 else { throw StateStoreError.fileUnwritable(name: Self.journalFileName) }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        if !existed {
            try Self.synchronizeDirectory(rootURL)
        }
    }

    /// Reads every record and lists the operations that never reached a terminal outcome.
    public func replay() throws -> JournalReplay {
        guard let data = try Self.readPrivateFile(at: journalURL) else {
            return JournalReplay(records: [], inFlight: [:], truncatedTail: false)
        }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var truncatedTail = false
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
        } else if !lines.isEmpty {
            truncatedTail = true
            lines.removeLast()
        }

        var records: [JournalRecord] = []
        var inFlight: [OperationID: JournalRecord] = [:]
        var identities: [OperationID: (EnvironmentID, JournalOperation)] = [:]
        for (index, line) in lines.enumerated() {
            // An empty line between records means bytes were lost; it is never skipped.
            guard !line.isEmpty, let record = try? decoder.decode(JournalRecord.self, from: line) else {
                throw StateStoreError.corruptJournal(line: index + 1)
            }
            if let (environment, operation) = identities[record.id] {
                guard record.outcome != .started, environment == record.environmentID, operation == record.operation else {
                    throw StateStoreError.corruptJournal(line: index + 1)
                }
            } else {
                guard record.outcome == .started else { throw StateStoreError.corruptJournal(line: index + 1) }
                identities[record.id] = (record.environmentID, record.operation)
            }
            records.append(record)
            if record.leavesInFlight {
                inFlight[record.id] = record
            } else {
                inFlight.removeValue(forKey: record.id)
            }
        }
        return JournalReplay(records: records, inFlight: inFlight, truncatedTail: truncatedTail)
    }

    private func validateIdentity(of record: JournalRecord) throws {
        let replay = try replay()
        let started = replay.records.first { $0.id == record.id }
        switch (record.outcome, started) {
        case (.started, nil):
            // A new mutation on an environment whose earlier one has no known outcome would be
            // a blind retry; the earlier one must be reconciled first.
            if let unresolved = replay.inFlight.values.first(where: { $0.environmentID == record.environmentID }) {
                throw StateStoreError.operationUnresolved(unresolved.id)
            }
            return
        case (.started, .some):
            throw StateStoreError.inconsistentRecord(record.id)
        case (_, nil):
            throw StateStoreError.inconsistentRecord(record.id)
        case (_, .some(let started)):
            guard started.environmentID == record.environmentID, started.operation == record.operation else {
                throw StateStoreError.inconsistentRecord(record.id)
            }
        }
    }

    // MARK: - Files

    /// Opens without following links, narrows the mode to `0600`, and reads. `nil` if absent.
    private static func readPrivateFile(at url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw StateStoreError.insecureDirectory(reason: "\(url.lastPathComponent) is a symbolic link")
            default: throw StateStoreError.insecureDirectory(reason: "\(url.lastPathComponent) cannot be opened")
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try requireRegularPrivateFile(descriptor, name: url.lastPathComponent)
        return try handle.readToEnd() ?? Data()
    }

    private static func requireRegularPrivateFile(_ descriptor: Int32, name: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw StateStoreError.insecureDirectory(reason: "\(name) is not a regular file")
        }
        if info.st_mode & 0o777 != 0o600 {
            guard fchmod(descriptor, 0o600) == 0 else { throw StateStoreError.insecureDirectory(reason: "\(name) cannot be made private") }
        }
    }

    /// Makes directory entries (a rename, a new file) durable.
    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw StateStoreError.insecureDirectory(reason: "cannot be opened") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw StateStoreError.fileUnwritable(name: url.lastPathComponent) }
    }

    private static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StateStoreError.insecureDirectory(reason: "not a directory") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw StateStoreError.insecureDirectory(reason: "symbolic link") }
        } else {
            do {
                try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw StateStoreError.fileUnwritable(name: url.lastPathComponent)
            }
            // The new entry in the parent is made durable too; otherwise a power loss could
            // lose the whole state directory after `begin` has reported a journal record.
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw StateStoreError.fileUnwritable(name: url.lastPathComponent)
        }
    }

    private func removeStaleTempFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootURL.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) {
            try? FileManager.default.removeItem(at: rootURL.appending(path: name))
        }
    }
}
