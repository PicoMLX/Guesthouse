import CoreFoundation
import Foundation

/// Applies explicitly registered transforms to a snapshot's version envelope (MVP-PLAN.md §3).
///
/// Migrations are keyed by the version they upgrade from and applied in sequence until the
/// document reaches `current`. A document newer than `current` is refused: an older build
/// must never silently rewrite state it does not understand. This helper does no file IO and
/// does not validate the complete snapshot. Callers must decode and validate the result before
/// durable publication; a successful transform is not proof that the records are consistent.
/// Registered transforms must be side-effect-free. Filesystem authority belongs to RuntimeKit.
/// Input and transform output must be UTF-8 JSON with an unambiguous top-level version.
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

    public init(current: SchemaVersion = EnvironmentsSnapshot.currentSchema, migrations: [Migration]) {
        self.current = current
        var byVersion: [Int: Migration] = [:]
        var ambiguous: SchemaVersion?
        for migration in migrations where byVersion.updateValue(migration, forKey: migration.from.rawValue) != nil {
            ambiguous = ambiguous ?? migration.from
        }
        self.migrations = byVersion
        ambiguousVersion = ambiguous
    }

    /// No prototype/format-2 transform is shipped. Older records may carry incompatible
    /// resume data or lack the original storage identity. Preserve them without inventing
    /// host facts. Future upgrades require an explicit, tested record transformation.
    public static let standard = SnapshotMigrator(migrations: [])

    /// Returns the document at `current`, and the version it was found at.
    public func migrate(_ data: Data) throws(StateStoreError) -> (data: Data, from: SchemaVersion) {
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
    static func object(in data: Data) throws(StateStoreError) -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data), let object = parsed as? [String: Any] else {
            throw StateStoreError.corruptSnapshot
        }
        return object
    }

    static func version(of data: Data) throws(StateStoreError) -> SchemaVersion {
        let object = try object(in: data)
        try requireUnambiguousMembers(in: data)
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

    /// Foundation validates the grammar above but collapses duplicate object members.
    /// Scan only the original top-level keys before choosing a transform. Persisted metadata
    /// and transform output use UTF-8 (as JSONEncoder does); refuse other encodings rather
    /// than scan a different representation from the one being returned or transformed.
    private static func requireUnambiguousMembers(in data: Data) throws(StateStoreError) {
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw .corruptSnapshot
        }
        let bytes = Array(data)
        var index = 0
        var depth = 0
        var keys: Set<String> = []
        while index < bytes.count {
            switch bytes[index] {
            case 123, 91: depth += 1 // { [
            case 125, 93: depth -= 1 // } ]
            case 34:
                let start = index
                index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 } // Skip an escaped byte, including quotes.
                    index += 1
                }
                guard index < bytes.count else { throw .corruptSnapshot }
                if depth == 1 {
                    var next = index + 1
                    while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                    if next < bytes.count && bytes[next] == 58 { // Only a member name precedes ':'.
                        guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index])) else {
                            throw .corruptSnapshot
                        }
                        guard keys.insert(key).inserted else { throw .corruptSnapshot }
                    }
                }
            default: break
            }
            index += 1
        }
    }
}
