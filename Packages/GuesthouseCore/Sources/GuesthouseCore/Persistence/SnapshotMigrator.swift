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
            guard version < next else { throw StateStoreError.migrationMissing(from: version) }
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

public enum StateStoreError: Error, Hashable, Sendable {
    case insecureDirectory(reason: String)
    case corruptSnapshot
    case corruptJournal(line: Int)
    case newerSchemaVersion(found: SchemaVersion, current: SchemaVersion)
    case migrationMissing(from: SchemaVersion)
}
