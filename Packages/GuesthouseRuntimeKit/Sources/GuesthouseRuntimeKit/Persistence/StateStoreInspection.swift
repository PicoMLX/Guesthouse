import Foundation
import GuesthouseCore

extension StateStore {
    /// Share the ordinary snapshot budget. Oversized state is preserved and refused,
    /// never truncated or silently replaced through either inspection or the writable store.
    static let inspectionByteLimit = StateFileIO.maximumSnapshotBytes

    /// Read-only prerequisite for retained-volume bootstrap (#12/#61; MVP-PLAN.md §§2–3).
    /// Reuses the store's anchored/locked file access, never StateStore.open or metadata
    /// preparation. Missing state is not readiness, durability proof or permission to select
    /// a replacement volume. Existing unsafe/incomplete layouts are preserved and refused.
    /// Synchronous native reads/lock waits belong on the bounded runtime worker, outside
    /// native callbacks and admission locks. No GUI/public path or dispatch API is added.
    static func inspectSnapshot(
        storage: () throws -> RuntimeStorage? = { try RuntimeStorage.existing() },
        migrator: SnapshotMigrator = .standard
    ) throws(StateStoreError) -> EnvironmentsSnapshot {
        do {
            guard let storage = try storage() else { return .empty }
            let anchor = try StateDirectoryAnchor(storage: storage)
            return try anchor.withFile(.readSnapshot, protection: .verifyOnly) { descriptor in
                let raw = try StateFileIO.readAll(descriptor, from: 0, name: .snapshot,
                                               maximumBytes: inspectionByteLimit)
                let migrated = try migrator.migrate(raw)
                do { return try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrated.data) }
                catch let failure as StateStoreError { throw failure }
                catch { throw StateStoreError.corruptSnapshot }
            } ?? .empty
        } catch let failure as StateStoreError { throw failure }
        catch { throw .fileUnreadable(name: .stateDirectory) }
    }
}
