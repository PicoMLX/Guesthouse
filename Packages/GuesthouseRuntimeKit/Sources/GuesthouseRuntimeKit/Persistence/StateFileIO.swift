import Darwin
import Foundation
import GuesthouseCore

/// Retained StateStore descriptor operations, now runtime-only (MVP-PLAN.md §3, issue #76).
/// Callers own and validate descriptors and hold their file lock through the complete transaction.
/// These synchronous helpers neither acquire ownership nor publish state. In particular, a write
/// failure can leave bytes behind; the journal owner must classify an attempted write as uncertain.
enum StateFileIO {
    /// Fixed snapshot budget, shared by ordinary load, save preflight and publication.
    static let maximumSnapshotBytes = 4 * 1024 * 1024
    /// Finite retained history budget. Reaching it refuses further appends; it never rotates,
    /// truncates or discards unresolved history automatically.
    static let maximumJournalBytes = 16 * 1024 * 1024

    /// Reads through observed EOF, with file size checked before allocation and on growth.
    /// Cache/identity validation and journal record-count policy remain owned by the store.
    /// Injected calls are synchronous test seams with the same return/errno contract as Darwin.
    static func readAll(
        _ descriptor: Int32, from offset: off_t, name: StateStoreError.File,
        readBytes: (Int32, UnsafeMutableRawPointer?, Int) -> Int = Darwin.read
    ) throws(StateStoreError) -> Data {
        let limit = name == .snapshot ? maximumSnapshotBytes : maximumJournalBytes
        guard offset >= 0, offset <= off_t(limit) else { throw .fileUnreadable(name: name) }
        let remaining = limit - Int(offset)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0,
              info.st_size <= off_t(limit) else { throw .fileUnreadable(name: name) }
        guard lseek(descriptor, offset, SEEK_SET) >= 0 else { throw .fileUnreadable(name: name) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { readBytes(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard count <= buffer.count else { throw .fileUnreadable(name: name) }
                if count > remaining - data.count {
                    throw .fileUnreadable(name: name)
                }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw .fileUnreadable(name: name)
            }
        }
    }

    static func writeAll(
        _ descriptor: Int32, _ data: Data, name: StateStoreError.File,
        writeBytes: (Int32, UnsafeRawPointer?, Int) -> Int = Darwin.write
    ) throws(StateStoreError) {
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { raw in
                writeBytes(descriptor, raw.baseAddress! + written, data.count - written)
            }
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw .fileUnwritable(name: name)
            }
        }
    }

    /// Requests F_FULLFSYNC first, preserving #57's explicit fsync fallback error set.
    /// Apple's fsync(2)/fcntl(2) distinguish host-to-device flush from device-cache flush:
    /// fallback success is NOT an equivalent power-loss guarantee or proof of publication.
    /// Neither this helper nor a successful barrier verifies the file's current directory entry.
    static func fullySynchronize(
        _ descriptor: Int32, name: StateStoreError.File,
        fullSync: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) },
        fallbackSync: (Int32) -> Int32 = Darwin.fsync
    ) throws(StateStoreError) {
        if fullSync(descriptor) == 0 { return }
        switch errno {
        case ENOTSUP, ENOTTY, EINVAL, EPERM, ENODEV:
            guard fallbackSync(descriptor) == 0 else { throw .fileUnwritable(name: name) }
        default:
            throw .fileUnwritable(name: name)
        }
    }

    /// Advisory only: callers retain the descriptor and lock across refresh/write/barriers.
    /// Never upgrade a shared lock to exclusive between validation and publication.
    static func lock(
        _ descriptor: Int32, _ operation: Int32,
        apply: (Int32, Int32) -> Int32 = { flock($0, $1) }
    ) -> Bool {
        while apply(descriptor, operation) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }

    static func version(_ descriptor: Int32, name: StateStoreError.File) throws(StateStoreError) -> StateFileVersion {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .fileUnwritable(name: name) }
        return StateFileVersion(info)
    }
}

struct StateFileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

/// Retained cache/publication evidence, not a durable capability or ownership/protection check.
/// Same-inode rewrites/reattachments require both timestamps, including their nanoseconds.
/// The journal owner separately checks file length against its validated byte offset.
struct StateFileVersion: Hashable, Sendable {
    let identity: StateFileIdentity
    let modified: Int64
    let modifiedNanoseconds: Int
    let changed: Int64
    let changedNanoseconds: Int

    init(_ info: stat) {
        identity = StateFileIdentity(info)
        modified = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changed = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}
