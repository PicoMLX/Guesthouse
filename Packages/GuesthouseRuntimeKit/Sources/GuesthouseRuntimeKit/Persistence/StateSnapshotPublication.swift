import Darwin
import Foundation
import GuesthouseCore

/// Atomic snapshot replacement adapted from #57 (MVP-PLAN.md §3). Runtime-internal and
/// synchronous: the caller first synchronizes directory preparation. A retained-directory
/// lock excludes other cooperating anchors throughout preflight and publication, independently
/// of actor instances. No descriptor, raw bytes or filesystem authority crosses the GUI boundary.
/// A failed publication may already be visible; preserve evidence and inspect before retrying.
enum StateSnapshotPublication {
    static let temporaryPrefix = ".environments.json.tmp-"

    static func save(
        _ snapshot: EnvironmentsSnapshot, to anchor: StateDirectoryAnchor,
        migrator: SnapshotMigrator = .standard,
        validateFirstSelection: () throws -> Void = {},
        permissionBarrier: StateFileProtection.Barrier = { try StateFileIO.fullySynchronize($0, name: $1) },
        fileBarrier: StateFileProtection.Barrier = { try StateFileIO.fullySynchronize($0, name: $1) },
        directoryBarrier: StateFileProtection.Barrier = { try StateFileIO.fullySynchronize($0, name: $1) },
        createTemporary: (Int32, String, Int32, mode_t) -> Int32 = { openat($0, $1, $2, $3) }
    ) throws(StateStoreError) {
        // Validate and encode before touching any saved state or temporary, including on
        // rejected prototype/newer values. Encoding can independently reject nonfinite dates.
        try snapshot.validate()
        guard snapshot.schemaVersion == migrator.current else {
            throw .unsupportedSnapshotVersion(found: snapshot.schemaVersion, current: migrator.current)
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            data = try encoder.encode(snapshot)
        } catch { throw .unencodable(name: .snapshot) }
        // Never publish bytes that the ordinary read/preflight budget would refuse.
        guard data.count <= StateFileIO.maximumSnapshotBytes else { throw .unencodable(name: .snapshot) }

        // Refuse existing unsupported/corrupt bytes as well as unsafe file structure.
        // A valid in-memory value is not permission to erase an unreadable saved version.
        try anchor.withPublicationOwnership { directory in
            let existing = try existingVersion(in: anchor, replacingWith: snapshot,
                                              migrator: migrator, permissionBarrier: permissionBarrier)
            if snapshot.storageSelection != nil, existing?.selection == nil {
                do { try validateFirstSelection() }
                catch let failure as StateStoreError { throw failure }
                catch { throw StateStoreError.storageSelectionChanged }
            }
            try StateSnapshotTemporaries.collect(in: directory, validateStore: { version in
                try anchor.verifyCurrent(version: version)
                try requireUnchangedSnapshot(in: directory, expected: existing?.version)
            })
            let name = temporaryPrefix + UUID().uuidString
            let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK
            // open(2) obtains this advisory lock atomically with creation. No unlocked
            // ENOTSUP fallback: a later stale-temp collector could claim that gap. One
            // failed open is a closed failure; never unlink an entry we did not acquire.
            let descriptor = createTemporary(directory, name, flags, 0o600)
            guard descriptor >= 0 else { throw StateStoreError.fileUnwritable(name: .snapshot) }
            defer { close(descriptor) } // Retain the live-writer lock through every barrier.
            try requireBinding(descriptor, in: directory, name: name)
            try anchor.verifyCurrent()
            try StateFileProtection.prepare(descriptor, kind: .regularFile, name: .snapshot,
                synchronize: { fd, label in
                    let fileVersion = try StateFileIO.version(fd, name: label)
                    let directoryVersion = try anchor.verifyCurrent()
                    try permissionBarrier(fd, label)
                    try verifyTemporary(fd, in: directory, name: name, version: fileVersion)
                    try anchor.verifyCurrent(version: directoryVersion)
                })
            try StateFileIO.writeAll(descriptor, data, name: .snapshot)
            let written = try StateFileIO.version(descriptor, name: .snapshot)
            let beforePublication = try anchor.verifyCurrent()
            try synchronize(descriptor, name: .snapshot, using: fileBarrier)
            try verifyTemporary(descriptor, in: directory, name: name, version: written)
            try anchor.verifyCurrent(version: beforePublication)
            try requireUnchangedSnapshot(in: directory, expected: existing?.version)
            guard renameat(directory, name, directory, StateFileAccess.readSnapshot.name) == 0 else {
                throw StateStoreError.fileUnwritable(name: .snapshot)
            }
            let published = try StateFileEntry.verifyCurrent(descriptor, in: directory, access: .readSnapshot)
            let directoryVersion = try anchor.verifyCurrent()
            try synchronize(directory, name: .stateDirectory, using: directoryBarrier)
            try StateFileEntry.verifyCurrent(descriptor, in: directory, access: .readSnapshot, version: published)
            try anchor.verifyCurrent(version: directoryVersion)
        }
        // Cleanup runs only after valid preflight, before this attempt creates a temporary.
        // Its failed write and live/unsafe/unknown files are never deleted on the error path.
    }

    private static func synchronize(
        _ descriptor: Int32, name: StateStoreError.File, using barrier: StateFileProtection.Barrier
    ) throws(StateStoreError) {
        do { try barrier(descriptor, name) }
        catch let failure as StateStoreError { throw failure }
        catch { throw .fileUnwritable(name: name) }
    }

    private static func existingVersion(
        in anchor: StateDirectoryAnchor, replacingWith snapshot: EnvironmentsSnapshot, migrator: SnapshotMigrator,
        permissionBarrier: StateFileProtection.Barrier
    ) throws(StateStoreError) -> (version: StateFileVersion, selection: HostStorageSelection?)? {
        try anchor.withFile(.readSnapshot, permissionBarrier: permissionBarrier, body: { descriptor in
            let raw = try StateFileIO.readAll(descriptor, from: 0, name: .snapshot)
            let migrated = try migrator.migrate(raw)
            let saved: EnvironmentsSnapshot
            do { saved = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrated.data) }
            catch let failure as StateStoreError { throw failure }
            catch { throw StateStoreError.corruptSnapshot }
            // Ordinary snapshot saves must retain the original binding, including when a
            // caller supplies an otherwise-empty replacement. Never bless preexisting work
            // with a newly observed UUID. Explicit relocation/recovery is a separate workflow.
            if let selected = saved.storageSelection {
                guard snapshot.storageSelection == selected else { throw StateStoreError.storageSelectionChanged }
            } else if snapshot.storageSelection != nil, !saved.environments.isEmpty {
                throw StateStoreError.storageSelectionChanged
            }
            return (try StateFileIO.version(descriptor, name: .snapshot), saved.storageSelection)
        })
    }

    /// This is a last pre-publication check, not a compare-and-swap or a namespace lock.
    /// Publication ownership excludes cooperating writers; arbitrary same-user changes remain outside it.
    private static func requireUnchangedSnapshot(
        in directory: Int32, expected: StateFileVersion?
    ) throws(StateStoreError) {
        var entry = stat()
        let result = fstatat(directory, StateFileAccess.readSnapshot.name, &entry, AT_SYMLINK_NOFOLLOW)
        if let expected {
            guard result == 0, StateFileVersion(entry) == expected else { throw .fileUnwritable(name: .snapshot) }
            try StateFileProtection.validateStructure(entry, kind: .regularFile)
        } else {
            guard result == -1, errno == ENOENT else { throw .fileUnwritable(name: .snapshot) }
        }
    }

    private static func verifyTemporary(
        _ descriptor: Int32, in directory: Int32, name: String, version: StateFileVersion
    ) throws(StateStoreError) {
        let info = try StateFileProtection.verify(descriptor, kind: .regularFile)
        let entry = try requireBinding(descriptor, in: directory, name: name)
        guard StateFileVersion(info) == version, StateFileVersion(entry) == version else {
            throw .fileUnwritable(name: .snapshot)
        }
    }

    @discardableResult private static func requireBinding(
        _ descriptor: Int32, in directory: Int32, name: String
    ) throws(StateStoreError) -> stat {
        var opened = stat(), entry = stat()
        guard fstat(descriptor, &opened) == 0, fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              StateFileIdentity(opened) == StateFileIdentity(entry) else { throw .fileUnwritable(name: .snapshot) }
        try StateFileProtection.validateStructure(opened, kind: .regularFile)
        try StateFileProtection.validateStructure(entry, kind: .regularFile)
        return entry
    }
}
