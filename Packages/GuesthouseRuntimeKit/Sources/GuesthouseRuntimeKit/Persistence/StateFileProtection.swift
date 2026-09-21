import Darwin
import GuesthouseCore

/// Descriptor-bound protection adapted from #57 (MVP-PLAN.md §3, ADR 0003).
/// Borrowed descriptors must remain exclusively owned by the caller. This does not anchor a
/// pathname or prevent same-user races; the store still verifies its directory/entry and locks.
enum StateFileProtection {
    enum Kind: Sendable {
        case regularFile, directory
        var mode: mode_t { self == .regularFile ? 0o600 : 0o700 }
    }
    typealias MetadataReader = (Int32, UnsafeMutablePointer<stat>?, filesec_t?) -> Int32
    typealias Barrier = (Int32, StateStoreError.File) throws -> Void

    /// Preparation may change metadata before failing. Never deletes, rolls back, or rewrites bytes.
    /// Even already-private metadata needs the barrier: a previous repair may not have persisted.
    @discardableResult static func prepare(
        _ descriptor: Int32, kind: Kind, name: StateStoreError.File,
        synchronize: Barrier = { try StateFileIO.fullySynchronize($0, name: $1) },
        readMetadata: MetadataReader = fstatx_np
    ) throws(StateStoreError) -> stat {
        let before = try inspect(descriptor, kind: kind, readMetadata: readMetadata)
        if before.info.st_mode & 0o7777 != kind.mode {
            guard fchmod(descriptor, kind.mode) == 0 else { throw .insecureDirectory(reason: .permissions) }
        }
        if before.aclPresent {
            guard let empty = acl_init(0) else { throw .insecureDirectory(reason: .permissions) }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            guard acl_set_fd(descriptor, empty) == 0 else { throw .insecureDirectory(reason: .permissions) }
        }
        do { try synchronize(descriptor, name) }
        catch let error as StateStoreError { throw error }
        catch { throw .fileUnwritable(name: name) }
        let after = try verify(descriptor, kind: kind, readMetadata: readMetadata)
        guard StateFileIdentity(before.info) == StateFileIdentity(after) else {
            throw .insecureDirectory(reason: .changed)
        }
        return after
    }

    /// Read-only point-in-time verification; never silently repairs protection drift.
    @discardableResult static func verify(
        _ descriptor: Int32, kind: Kind, readMetadata: MetadataReader = fstatx_np
    ) throws(StateStoreError) -> stat {
        let current = try inspect(descriptor, kind: kind, readMetadata: readMetadata)
        guard current.info.st_mode & 0o7777 == kind.mode, !current.hasEntries else {
            throw .insecureDirectory(reason: .permissions)
        }
        return current.info
    }

    static func validateStructure(_ info: stat, kind: Kind) throws(StateStoreError) {
        let expected = kind == .regularFile ? S_IFREG : S_IFDIR
        guard info.st_mode & S_IFMT == expected else {
            throw .insecureDirectory(reason: kind == .regularFile ? .notRegularFile : .notDirectory)
        }
        guard info.st_uid == getuid() else { throw .insecureDirectory(reason: .permissions) }
        if kind == .regularFile, info.st_nlink != 1 { throw .insecureDirectory(reason: .multipleLinks) }
    }

    private struct Metadata {
        let info: stat
        let aclPresent: Bool
        let hasEntries: Bool
    }

    private static func inspect(
        _ descriptor: Int32, kind: Kind, readMetadata: MetadataReader
    ) throws(StateStoreError) -> Metadata {
        guard let security = filesec_init() else { throw .insecureDirectory(reason: .aclUnreadable) }
        defer { filesec_free(security) }
        var info = stat()
        // Apple Libc 71bbe350: acl_get_fd conflates fstatx failure with absent FILESEC_ACL.
        // Query presence only after successful descriptor metadata, as StorageProtection does
        // for paths. Never interpret lookup ENOENT as proof of an empty ACL.
        guard readMetadata(descriptor, &info, security) == 0 else { throw .insecureDirectory(reason: .unreadable) }
        try validateStructure(info, kind: kind)
        var owner = uid_t(0), mode = mode_t(0), present: Int32 = 0
        guard filesec_get_property(security, FILESEC_OWNER, &owner) == 0, owner == info.st_uid,
              filesec_get_property(security, FILESEC_MODE, &mode) == 0, mode == info.st_mode,
              filesec_query_property(security, FILESEC_ACL, &present) == 0 else {
            throw .insecureDirectory(reason: .aclUnreadable)
        }
        guard present != 0 else { return Metadata(info: info, aclPresent: false, hasEntries: false) }
        var value: acl_t?
        guard filesec_get_property(security, FILESEC_ACL, &value) == 0, let acl = value else {
            throw .insecureDirectory(reason: .aclUnreadable)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw .insecureDirectory(reason: .aclUnreadable) }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry), error = errno
        if StorageProtection.enumerationFinished(result: result, error: error) {
            return Metadata(info: info, aclPresent: true, hasEntries: false)
        }
        guard result == 0, entry != nil else { throw .insecureDirectory(reason: .aclUnreadable) }
        return Metadata(info: info, aclPresent: true, hasEntries: true)
    }
}
