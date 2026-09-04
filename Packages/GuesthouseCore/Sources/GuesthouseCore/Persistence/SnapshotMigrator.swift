import Foundation

/// Upgrades an `EnvironmentsSnapshot` JSON document written by an older build.
///
/// Migrations are keyed by the version they upgrade from and applied in sequence until the
/// document reaches `current`. A document newer than `current` is refused: an older build
/// must never silently rewrite state it does not understand.
public struct SnapshotMigrator: Sendable {
    public struct Migration: Sendable {
        public let from: SchemaVersion
        public let apply: @Sendable (Data) throws -> Data

        public init(from: SchemaVersion, apply: @escaping @Sendable (Data) throws -> Data) {
            self.from = from
            self.apply = apply
        }
    }

    public let current: SchemaVersion
    private let migrations: [Int: Migration]
    /// A version two migrations claim to upgrade. Reported when a migration is attempted
    /// rather than trapped at construction: a duplicate in a future migration list would
    /// otherwise kill the app during static setup, before saved state could be inspected.
    private let ambiguousVersion: SchemaVersion?

    public init(current: SchemaVersion = .current, migrations: [Migration]) {
        self.current = current
        var byVersion: [Int: Migration] = [:]
        var ambiguous: SchemaVersion?
        for migration in migrations where byVersion.updateValue(migration, forKey: migration.from.rawValue) != nil {
            ambiguous = ambiguous ?? migration.from
        }
        self.migrations = byVersion
        ambiguousVersion = ambiguous
    }

    /// The migrations shipped with this build.
    ///
    /// `0 → 1`: documents written before versioning carry no `schemaVersion` key. They are
    /// treated as version 0 and receive the key; nothing else about them changes.
    public static let standard = SnapshotMigrator(migrations: [
        Migration(from: .unversioned) { data in
            var object = try SnapshotMigrator.object(in: data)
            object["schemaVersion"] = 1
            guard let upgraded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                throw StateStoreError.corruptSnapshot
            }
            return upgraded
        }
    ])

    /// Returns the document at `current`, and the version it was found at.
    public func migrate(_ data: Data) throws -> (data: Data, from: SchemaVersion) {
        if let ambiguousVersion { throw StateStoreError.duplicateMigration(from: ambiguousVersion) }
        var version = try Self.version(of: data)
        let original = version
        var document = data
        if current < version {
            throw StateStoreError.newerSchemaVersion(found: version, current: current)
        }
        while version < current {
            guard let migration = migrations[version.rawValue] else {
                throw StateStoreError.migrationMissing(from: version)
            }
            do {
                document = try migration.apply(document)
            } catch let failure as StateStoreError {
                throw failure
            } catch {
                // A migration is free to throw whatever its transform ran into. Letting that
                // escape would hand the user a raw Foundation error with no message of ours and
                // no recovery action (AGENTS.md: every error carries both).
                throw StateStoreError.migrationFailed(from: version)
            }
            let next = try Self.version(of: document)
            // Exactly one step, never past `current`: a migration that skips a version would
            // leave the intermediate transformations unapplied.
            guard next == SchemaVersion(version.rawValue + 1), next <= current else {
                throw StateStoreError.migrationProducedWrongVersion(from: version, produced: next)
            }
            version = next
        }
        return (document, original)
    }

    /// The document's top-level object. Syntactically invalid JSON is corruption like any
    /// other, reported with the store's recovery actions rather than as a Foundation error.
    static func object(in data: Data) throws -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data), let object = parsed as? [String: Any] else {
            throw StateStoreError.corruptSnapshot
        }
        return object
    }

    static func version(of data: Data) throws -> SchemaVersion {
        let object = try object(in: data)
        guard let raw = object["schemaVersion"] else { return .unversioned }
        // `true` and `false` arrive as boolean `NSNumber`s, which cast to 1 and 0. A document
        // whose version reads `false` would otherwise look unversioned and be rewritten as
        // version 1 instead of being reported as corrupt.
        guard CFGetTypeID(raw as CFTypeRef) != CFBooleanGetTypeID(), let value = raw as? Int else {
            throw StateStoreError.corruptSnapshot
        }
        // A document that carries a version at all must carry one a reader accepts: zero or a
        // negative number is not the unversioned case, it is damage.
        guard let version = SchemaVersion(value) else { throw StateStoreError.corruptSnapshot }
        return version
    }
}

/// Failures of the state store, each with a message and a recovery path (AGENTS.md: every
/// error carries a message and a recovery action).
public enum StateStoreError: Error, Hashable, Sendable, LocalizedError {
    case insecureDirectory(reason: String)
    case corruptSnapshot
    case inconsistentSnapshot(reason: String)
    case corruptJournal(line: Int)
    /// A journal line is well formed but written in a record format this build cannot read.
    /// Kept apart from damage: the fix is a newer Guesthouse, not an inspection.
    case unsupportedJournalFormat(line: Int, format: Int)
    /// A record reused an operation id with a different environment or operation.
    case inconsistentRecord(OperationID)
    /// A new operation was started on an environment whose earlier operation has no known
    /// outcome yet.
    case operationUnresolved(OperationID)
    case newerSchemaVersion(found: SchemaVersion, current: SchemaVersion)
    case migrationMissing(from: SchemaVersion)
    case migrationProducedWrongVersion(from: SchemaVersion, produced: SchemaVersion)
    /// A migration itself failed for a reason of its own.
    case migrationFailed(from: SchemaVersion)
    /// Two migrations claim the same version, so which one applies is undefined.
    case duplicateMigration(from: SchemaVersion)
    case fileUnwritable(name: String)
    case fileUnreadable(name: String)
    /// A value in memory cannot be written as JSON, so it was never saved.
    case unencodable(name: String)

    public var userMessage: String {
        switch self {
        case .insecureDirectory(let reason):
            "Guesthouse's state folder cannot be used (\(reason)). Choose a different storage location or move the item that is in the way."
        case .corruptSnapshot:
            "The saved list of development Macs could not be read. Guesthouse will inspect the actual virtual machines before offering anything."
        case .inconsistentSnapshot(let reason):
            "The saved list of development Macs is inconsistent (\(reason)). Guesthouse will inspect the actual virtual machines before offering anything."
        case .corruptJournal(let line):
            "The operation journal is damaged at line \(line). Guesthouse will inspect the actual state before allowing new operations."
        case .unsupportedJournalFormat(let line, let format):
            "The operation journal was written by a newer Guesthouse (record format \(format) at line \(line); this version reads format \(JournalRecord.currentFormat)). Update Guesthouse to continue."
        case .inconsistentRecord:
            "A journal record disagreed with the operation it belongs to, so it was not written. This is a bug in Guesthouse, not something you did."
        case .operationUnresolved:
            "An earlier operation on this development Mac has no recorded result yet. Guesthouse will check the actual state before starting another."
        case .newerSchemaVersion(let found, let current):
            "The saved state was written by a newer Guesthouse (format \(found.rawValue); this version reads format \(current.rawValue)). Update Guesthouse to continue."
        case .migrationMissing(let from):
            "The saved state (format \(from.rawValue)) cannot be upgraded by this version of Guesthouse."
        case .migrationProducedWrongVersion(let from, let produced):
            "Upgrading the saved state from format \(from.rawValue) produced format \(produced.rawValue), which is not the next step. This is a bug in Guesthouse."
        case .migrationFailed(let from):
            "Upgrading the saved state from format \(from.rawValue) did not succeed, so nothing was changed on disk."
        case .duplicateMigration(let from):
            "This version of Guesthouse offers two different upgrades of saved state from format \(from.rawValue), so it did not apply either. This is a bug in Guesthouse."
        case .fileUnwritable(let name):
            "Guesthouse could not write \(name) in its state folder."
        case .fileUnreadable(let name):
            "Guesthouse could not read \(name) in its state folder."
        case .unencodable(let name):
            "Guesthouse could not save \(name): one of the values could not be written. Nothing was changed on disk."
        }
    }

    /// In preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .insecureDirectory: [.openSettings, .cancel]
        case .corruptSnapshot, .inconsistentSnapshot, .corruptJournal, .inconsistentRecord, .operationUnresolved, .unencodable: [.inspectState, .cancel]
        case .unsupportedJournalFormat, .newerSchemaVersion, .migrationMissing, .migrationProducedWrongVersion, .migrationFailed, .duplicateMigration: [.reinstallApp, .cancel]
        case .fileUnwritable: [.freeDiskSpace, .openSettings, .cancel]
        case .fileUnreadable: [.inspectState, .openSettings, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}
