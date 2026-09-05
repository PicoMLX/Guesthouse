import Darwin
import Foundation
import GuesthouseCore

enum LumeOwnershipStorageFailure: Error, Equatable, Sendable, LocalizedError {
    case notEnrolled, invalidEnrollment, guardBusy, guardChanged, insecureFile, ioFailure
    case invalidLedger, staleRecord, poisoned, writeUncertain

    var errorDescription: String? {
        "Guesthouse cannot safely read or preserve runtime ownership. Keep its storage unchanged and inspect the actual state before another operation."
    }
    var recoveryActions: [RecoveryAction] { [.inspectState, .cancel] }
}

/// Immutable enrollment marker, independent of the replaceable ledger. Normal startup never
/// creates it. Both files being absent is NOT proof of a virgin runtime (MVP-PLAN.md §3/§4).
struct LumeOwnershipEnrollment: Codable, Equatable {
    let format: Int
    let id: UUID
    let rootDevice: Int64
    let rootInode: UInt64
}

/// Synchronous, actor-confined transaction guard, not process ownership or cleanup evidence.
/// The trusted root AND ancestry entries must remain stable for this object's lifetime.
/// Managed relocation requires quiescent ownership, closed users/guards, then a fresh open;
/// no claim is made against arbitrary external rename-away/restore between calls.
/// Enrollment is deliberately absent: no production provisioning/inspection authority exists.
final class LumeOwnershipGuard {
    static let fileName = ".lume-ownership.guard"
    let enrollment: LumeOwnershipEnrollment
    private let root: URL
    private let directory: Int32
    private let descriptor: Int32
    private let rootIdentity: RuntimeStorage.CoordinationIdentity
    private let guardVersion: LumeOwnershipFileVersion
    private var isLocked = false
    var identity: RuntimeStorage.CoordinationIdentity { guardVersion.identity }

    init(storage: RuntimeStorage, barrier: (Int32) throws -> Void = LumeOwnershipIO.synchronize) throws {
        try Self.requireRoot(storage.root)
        let directory = open(storage.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw LumeOwnershipStorageFailure.ioFailure }
        var marker: Int32 = -1
        do {
            let rootInfo = try LumeOwnershipIO.info(directory)
            let rootVersion = LumeOwnershipFileVersion(rootInfo)
            marker = try LumeOwnershipIO.openExisting(Self.fileName, in: directory)
            guard flock(marker, LOCK_EX | LOCK_NB) == 0 else { throw LumeOwnershipStorageFailure.guardBusy }
            defer { flock(marker, LOCK_UN) }
            let guardVersion = try LumeOwnershipIO.version(marker)
            try LumeOwnershipIO.requirePrivateFile(marker)
            let bytes = try LumeOwnershipIO.readBounded(marker, limit: 4_096)
            guard let enrollment = try? JSONDecoder().decode(LumeOwnershipEnrollment.self, from: bytes),
                  enrollment.format == 1, enrollment.rootDevice == Int64(rootInfo.st_dev),
                  enrollment.rootInode == UInt64(rootInfo.st_ino) else {
                throw LumeOwnershipStorageFailure.invalidEnrollment
            }
            // Visible entries may be leftovers from an interrupted durability barrier. Flush
            // the marker, root and both lexical/physical ancestry chains on every opening.
            try barrier(marker)
            try Self.synchronizeAncestry(storage.root, barrier: barrier)
            try Self.requireRoot(storage.root)
            try LumeOwnershipIO.requirePrivateFile(marker)
            guard RuntimeStorage.fileIdentity(of: storage.root) == rootVersion.identity,
                  try LumeOwnershipIO.version(directory) == rootVersion,
                  try LumeOwnershipIO.version(marker) == guardVersion else {
                throw LumeOwnershipStorageFailure.guardChanged
            }
            try LumeOwnershipIO.requireEntry(marker, named: Self.fileName, in: directory)
            self.root = storage.root
            self.directory = directory
            descriptor = marker
            self.enrollment = enrollment
            rootIdentity = rootVersion.identity
            self.guardVersion = guardVersion
        } catch {
            if marker >= 0 { close(marker) }
            close(directory)
            throw error
        }
    }

    deinit { close(descriptor); close(directory) }

    /// The descriptor is borrowed only for this non-suspending closure. It must not escape or
    /// be closed. flock serializes ledger transactions; unlocking never clears a lease record.
    func withLock<T>(_ operation: (Int32, LumeOwnershipEnrollment) throws -> T) throws -> T {
        guard !isLocked else { throw LumeOwnershipStorageFailure.guardBusy }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LumeOwnershipStorageFailure.guardBusy }
        isLocked = true
        defer { isLocked = false; flock(descriptor, LOCK_UN) }
        try validate()
        let result = try operation(directory, enrollment)
        try validate()
        return result
    }

    /// Recheck after each durability barrier too, before a transaction reports success.
    func validate() throws {
        guard isLocked else { throw LumeOwnershipStorageFailure.guardBusy }
        try Self.requireRoot(root)
        guard RuntimeStorage.fileIdentity(of: root) == rootIdentity,
              try LumeOwnershipIO.version(directory).identity == rootIdentity,
              try LumeOwnershipIO.version(descriptor) == guardVersion else {
            throw LumeOwnershipStorageFailure.guardChanged
        }
        try LumeOwnershipIO.requirePrivateFile(descriptor)
        try LumeOwnershipIO.requireEntry(descriptor, named: Self.fileName, in: directory)
        guard try LumeOwnershipIO.version(descriptor) == guardVersion else {
            throw LumeOwnershipStorageFailure.guardChanged
        }
    }

    private static func requireRoot(_ root: URL) throws {
        do { try RuntimeStorage.verify(root) }
        catch { throw LumeOwnershipStorageFailure.insecureFile }
    }

    private static func synchronizeAncestry(_ root: URL, barrier: (Int32) throws -> Void) throws {
        guard let resolved = realpath(root.path, nil) else { throw LumeOwnershipStorageFailure.ioFailure }
        defer { free(resolved) }
        let physical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var visited: Set<String> = []
        for location in [physical, root] {
            var directories: [URL] = [location]
            var current = location
            while current.path != "/" {
                current = current.deletingLastPathComponent()
                directories.append(current)
            }
            for url in directories.reversed() where visited.insert(url.path).inserted {
                let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard fd >= 0 else { throw LumeOwnershipStorageFailure.ioFailure }
                defer { close(fd) }
                try barrier(fd)
            }
        }
    }
}

struct LumeOwnershipFileVersion: Equatable {
    let identity: RuntimeStorage.CoordinationIdentity
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
        identity = .init(device: info.st_dev, inode: info.st_ino)
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

/// Descriptor-relative primitives shared only by the inactive ownership store. Unlike a
/// preparer, they refuse protection drift instead of repairing possibly foreign metadata.
enum LumeOwnershipIO {
    static func info(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw LumeOwnershipStorageFailure.ioFailure }
        return value
    }

    static func version(_ descriptor: Int32) throws -> LumeOwnershipFileVersion {
        try LumeOwnershipFileVersion(info(descriptor))
    }

    static func openExisting(_ name: String, in directory: Int32) throws -> Int32 {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ENOENT ? LumeOwnershipStorageFailure.notEnrolled : .insecureFile
        }
        return fd
    }

    static func requireEntry(_ descriptor: Int32, named name: String, in directory: Int32) throws {
        var entry = stat()
        guard fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              try version(descriptor).identity == LumeOwnershipFileVersion(entry).identity else {
            throw LumeOwnershipStorageFailure.guardChanged
        }
    }

    static func requirePrivateFile(_ descriptor: Int32) throws {
        let value = try info(descriptor)
        guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(), value.st_nlink == 1,
              value.st_mode & 0o7777 == 0o600 else { throw LumeOwnershipStorageFailure.insecureFile }
        errno = 0
        guard let acl = acl_get_fd(descriptor) else {
            guard errno == ENOENT else { throw LumeOwnershipStorageFailure.insecureFile }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        let status = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard status != 0, errno == EINVAL || errno == 0 else {
            throw LumeOwnershipStorageFailure.insecureFile
        }
    }

    static func readBounded(_ descriptor: Int32, limit: Int) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw LumeOwnershipStorageFailure.ioFailure }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw LumeOwnershipStorageFailure.ioFailure
            }
            guard count <= limit - data.count else { throw LumeOwnershipStorageFailure.invalidEnrollment }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// Matches final StateStore #57's barrier policy; unsupported full sync falls back to the
    /// volume's fsync contract. Tests inject faults; they do not simulate on-media power loss.
    static func synchronize(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        switch errno {
        case ENOTSUP, ENOTTY, EINVAL, EPERM, ENODEV:
            guard fsync(descriptor) == 0 else { throw LumeOwnershipStorageFailure.ioFailure }
        default: throw LumeOwnershipStorageFailure.ioFailure
        }
    }
}
