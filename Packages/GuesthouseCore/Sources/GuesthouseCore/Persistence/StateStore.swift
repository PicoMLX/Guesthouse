import Foundation

/// Owns the on-disk state of the app: a versioned JSON snapshot and an append-only journal.
///
/// - The snapshot is replaced atomically (temp file, fsync, rename), so a crash mid-write
///   leaves the previous snapshot intact.
/// - The journal is newline-delimited JSON, appended and fsynced per record. `begin` returns
///   an `OperationID` only after its `started` record is durable, so an operation can never
///   be running without the journal knowing.
/// - The directory is created `0700` and every file `0600` (MVP-PLAN.md §3, "Local storage").
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

        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let encodeDate: @Sendable (Date, any Encoder) throws -> Void = { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(style.format(date))
        }
        let decodeDate: @Sendable (any Decoder) throws -> Date = { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            do {
                return try style.parse(string)
            } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(string)"))
            }
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom(encodeDate)
        lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys]
        lineEncoder.dateEncodingStrategy = .custom(encodeDate)
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDate)

        try Self.prepareDirectory(rootURL)
    }

    // MARK: - Snapshot

    public var snapshotURL: URL { rootURL.appending(path: Self.snapshotFileName) }
    public var journalURL: URL { rootURL.appending(path: Self.journalFileName) }

    /// The saved snapshot, migrated to the current schema, or `.empty` if none exists.
    public func loadSnapshot() throws -> EnvironmentsSnapshot {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return .empty }
        let raw = try Data(contentsOf: snapshotURL)
        let (data, _) = try migrator.migrate(raw)
        do {
            return try decoder.decode(EnvironmentsSnapshot.self, from: data)
        } catch {
            throw StateStoreError.corruptSnapshot
        }
    }

    /// Replaces the snapshot atomically. Stale temp files from an earlier crash are removed.
    public func saveSnapshot(_ snapshot: EnvironmentsSnapshot) throws {
        var stamped = snapshot
        stamped.schemaVersion = migrator.current
        let data = try encoder.encode(stamped)

        removeStaleTempFiles()
        let tempURL = rootURL.appending(path: Self.tempPrefix + UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: tempURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        guard rename(tempURL.path, snapshotURL.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }

    // MARK: - Journal

    /// Appends a `started` record and returns its id only once the record is on disk.
    public func begin(_ operation: String, for environmentID: EnvironmentID, at timestamp: Date = Date()) throws -> OperationID {
        let id = OperationID()
        try append(JournalRecord(id: id, environmentID: environmentID, operation: operation, timestamp: timestamp, outcome: .started))
        return id
    }

    /// Appends one record and fsyncs before returning.
    public func append(_ record: JournalRecord) throws {
        var line = try lineEncoder.encode(record)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            FileManager.default.createFile(atPath: journalURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// Reads every record and lists the operations that never reached a terminal outcome.
    public func replay() throws -> JournalReplay {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return JournalReplay(records: [], inFlight: [:], truncatedTail: false)
        }
        let data = try Data(contentsOf: journalURL)
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
        for (index, line) in lines.enumerated() where !line.isEmpty {
            guard let record = try? decoder.decode(JournalRecord.self, from: line) else {
                throw StateStoreError.corruptJournal(line: index + 1)
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

    // MARK: - Directory

    private static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StateStoreError.insecureDirectory(reason: "not a directory") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw StateStoreError.insecureDirectory(reason: "symbolic link") }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func removeStaleTempFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootURL.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) {
            try? FileManager.default.removeItem(at: rootURL.appending(path: name))
        }
    }
}
