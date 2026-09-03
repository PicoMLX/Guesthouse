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

    public init(current: SchemaVersion = .current, migrations: [Migration]) {
        self.current = current
        self.migrations = Dictionary(uniqueKeysWithValues: migrations.map { ($0.from.rawValue, $0) })
    }

    /// The migrations shipped with this build.
    ///
    /// `0 → 1`: documents written before versioning carry no `schemaVersion` key. They are
    /// treated as version 0 and receive the key; nothing else about them changes.
    public static let standard = SnapshotMigrator(migrations: [
        Migration(from: SchemaVersion(0)) { data in
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StateStoreError.corruptSnapshot
            }
            object["schemaVersion"] = 1
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    ])

    /// Returns the document at `current`, and the version it was found at.
    public func migrate(_ data: Data) throws -> (data: Data, from: SchemaVersion) {
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
            document = try migration.apply(document)
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

    static func version(of data: Data) throws -> SchemaVersion {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StateStoreError.corruptSnapshot
        }
        guard let raw = object["schemaVersion"] else { return SchemaVersion(0) }
        guard let value = raw as? Int else { throw StateStoreError.corruptSnapshot }
        return SchemaVersion(value)
    }
}

/// Failures of the state store, each with a message and a recovery path (AGENTS.md: every
/// error carries a message and a recovery action).
public enum StateStoreError: Error, Hashable, Sendable, LocalizedError {
    case insecureDirectory(reason: String)
    case corruptSnapshot
    case inconsistentSnapshot(reason: String)
    case corruptJournal(line: Int)
    /// A record reused an operation id with a different environment or operation.
    case inconsistentRecord(OperationID)
    case newerSchemaVersion(found: SchemaVersion, current: SchemaVersion)
    case migrationMissing(from: SchemaVersion)
    case migrationProducedWrongVersion(from: SchemaVersion, produced: SchemaVersion)
    case fileUnwritable(name: String)

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
        case .inconsistentRecord:
            "A journal record disagreed with the operation it belongs to, so it was not written. This is a bug in Guesthouse, not something you did."
        case .newerSchemaVersion(let found, let current):
            "The saved state was written by a newer Guesthouse (format \(found.rawValue); this version reads format \(current.rawValue)). Update Guesthouse to continue."
        case .migrationMissing(let from):
            "The saved state (format \(from.rawValue)) cannot be upgraded by this version of Guesthouse."
        case .migrationProducedWrongVersion(let from, let produced):
            "Upgrading the saved state from format \(from.rawValue) produced format \(produced.rawValue), which is not the next step. This is a bug in Guesthouse."
        case .fileUnwritable(let name):
            "Guesthouse could not write \(name) in its state folder."
        }
    }

    /// In preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .insecureDirectory: [.openSettings, .cancel]
        case .corruptSnapshot, .inconsistentSnapshot, .corruptJournal, .inconsistentRecord: [.inspectState, .cancel]
        case .newerSchemaVersion, .migrationMissing, .migrationProducedWrongVersion: [.reinstallApp, .cancel]
        case .fileUnwritable: [.freeDiskSpace, .openSettings, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}
