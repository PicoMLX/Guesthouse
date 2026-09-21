import Darwin
import Foundation
import GuesthouseCore

/// Retained #57 stale-temp isolation (MVP-PLAN.md §3), narrowed to the runtime's exact names.
/// The caller first validates the value and existing snapshot, then keeps its directory borrow
/// and snapshot precondition throughout this synchronous call. No arbitrary paths or GUI API.
enum StateSnapshotTemporaries {
    // Bound retained names and enumeration work independently. Every retained name has
    // a fixed ASCII prefix + 36-byte UUID length. Overflow refuses before any move.
    static let maximumCandidates = 256
    static let maximumDirectoryEntries = 4_096
    static let quarantinePrefix = ".environments.json.quarantine-"

    static func isManagedName(_ name: String) -> Bool {
        hasGeneratedSuffix(name, prefix: StateSnapshotPublication.temporaryPrefix)
    }

    private static func hasGeneratedSuffix(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))) else { return false }
        // UUID() produces RFC 4122 variant, version 4 identifiers. Canonical spelling
        // alone also admits nil/foreign UUIDs and must not grant collection authority.
        let bytes = id.uuid
        return name == prefix + id.uuidString && bytes.6 & 0xF0 == 0x40 && bytes.8 & 0xC0 == 0x80
    }

    /// Collection moves candidates out of the publication namespace but NEVER erases bytes.
    /// Quarantine is deliberately not eligible for automatic deletion or rollback: a later
    /// snapshot/anchor/barrier refusal must not lose recovery evidence. The joint name budget
    /// bounds retention; exhaustion refuses until explicit inspection outside this API.
    /// Native locks coordinate cooperating writers, not arbitrary same-user namespace races.
    @discardableResult static func collect(
        in directory: Int32, reservingPublicationTemporary: Bool = false,
        validateStore: (StateFileVersion?) throws -> Void,
        beforeRemoval: (Int32, String) throws -> Void = { _, _ in },
        moveToQuarantine: (Int32, String, String) throws -> Int32 = {
            renameatx_np($0, $1, $0, $2, UInt32(RENAME_EXCL))
        }
    ) throws(StateStoreError) -> Int {
        do {
            try validateStore(nil)
            // Snapshot names before moving; never rely on readdir's unspecified ordering
            // or on a stream's position while its directory entries are changing.
            // Publication may leave its new temporary behind on failure. Reserve that
            // retained name before ANY move, not after collecting the existing inventory.
            let limit = maximumCandidates - (reservingPublicationTemporary ? 1 : 0)
            let names = try candidates(in: directory, limit: limit)
            var quarantined = 0
            for name in names {
                try validateStore(nil)
                if try quarantine(name, in: directory, validateStore: validateStore,
                                  beforeRemoval: beforeRemoval, move: moveToQuarantine) {
                    quarantined += 1
                }
            }
            try validateStore(nil)
            return quarantined
        } catch let failure as StateStoreError { throw failure }
        catch { throw .fileUnwritable(name: .snapshot) }
    }

    private static func candidates(in directory: Int32, limit: Int) throws(StateStoreError) -> [String] {
        // An independent open description keeps enumeration from changing the anchor's offset.
        // fdopendir takes ownership only on success; closedir then closes that descriptor.
        let descriptor = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .fileUnreadable(name: .stateDirectory) }
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            throw .fileUnreadable(name: .stateDirectory)
        }
        defer { closedir(stream) }
        var names: [String] = []
        var inspected = 0
        var retained = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw .fileUnreadable(name: .stateDirectory) }
                return names
            }
            guard inspected < maximumDirectoryEntries else { throw .fileUnreadable(name: .stateDirectory) }
            inspected += 1 // Includes unrelated entries and the directory's dot entries.
            let length = Int(entry.pointee.d_namlen)
            guard length == StateSnapshotPublication.temporaryPrefix.utf8.count + 36
                    || length == quarantinePrefix.utf8.count + 36 else { continue }
            // dir(5) records are packed to their actual length. Borrow the first character's
            // address, not a value copy of the whole imported 1024-byte d_name tuple.
            let name = withUnsafePointer(to: &entry.pointee.d_name.0) { start -> String? in
                let offset = UnsafeRawPointer(entry).distance(to: UnsafeRawPointer(start))
                guard offset >= 0, offset + length < Int(entry.pointee.d_reclen) else { return nil }
                let bytes = UnsafeRawPointer(start).assumingMemoryBound(to: UInt8.self)
                guard bytes[length] == 0 else { return nil }
                return String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8)
            }
            // d_type is deliberately ignored: it is optional filesystem-supplied evidence.
            if let name, isManagedName(name) || hasGeneratedSuffix(name, prefix: quarantinePrefix) {
                guard retained < limit else { throw .fileUnreadable(name: .stateDirectory) }
                retained += 1
                if isManagedName(name) { names.append(name) }
            }
        }
    }

    private static func quarantine(
        _ name: String, in directory: Int32, validateStore: (StateFileVersion?) throws -> Void,
        beforeRemoval: (Int32, String) throws -> Void,
        move: (Int32, String, String) throws -> Int32
    ) throws -> Bool {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // Read-only inspection: do not repair suspicious files to make them eligible for
        // movement. NONBLOCK lets unexpected FIFOs be refused without waiting for a writer.
        guard (try? StateFileProtection.verify(descriptor, kind: .regularFile)) != nil,
              StateFileIO.lock(descriptor, LOCK_EX | LOCK_NB),
              let version = boundVersion(descriptor, in: directory, name: name) else { return false }
        let directoryVersion = try StateFileIO.version(directory, name: .stateDirectory)
        // Internal synchronous seam for namespace/protection/lock regressions. Checks follow
        // the seam, not the other way around; production supplies the empty default closure.
        try beforeRemoval(descriptor, name)
        try validateStore(directoryVersion)
        guard boundVersion(descriptor, in: directory, name: name) == version else { return false }
        let retainedName = quarantinePrefix + UUID().uuidString
        // Exactly one no-overwrite move; unsupported flags/collision/uncertain errors refuse.
        // Never fall back to renameat, retry a mutation, or move an unknown entry back.
        guard try move(directory, name, retainedName) == 0 else {
            throw StateStoreError.fileUnwritable(name: .snapshot)
        }
        // The move itself changes namespace timestamps. Revalidate the moved binding and
        // protection against our still-locked descriptor, not the now-absent original name.
        // A raced replacement remains in quarantine, even when it fails this check.
        guard let retained = boundVersion(descriptor, in: directory, name: retainedName),
              retained.identity == version.identity,
              retained.modified == version.modified,
              retained.modifiedNanoseconds == version.modifiedNanoseconds else {
            throw StateStoreError.fileUnwritable(name: .snapshot)
        }
        try validateStore(nil)
        return true
    }

    private static func boundVersion(_ descriptor: Int32, in directory: Int32, name: String) -> StateFileVersion? {
        guard let opened = try? StateFileProtection.verify(descriptor, kind: .regularFile) else { return nil }
        var entry = stat()
        guard fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              // Preserve all flagged artifacts, including immutable/append/no-unlink
              // evidence. Never clear flags or attempt deletion to discover eligibility.
              opened.st_flags == 0, entry.st_flags == 0,
              StateFileVersion(opened) == StateFileVersion(entry) else { return nil }
        return StateFileVersion(opened)
    }
}
