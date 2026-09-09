import Darwin
import Darwin.membership
import Foundation
import GuesthouseCore

/// Closed failures only: no filesystem paths, ACL text or underlying error descriptions
/// reach error presentation or diagnostics (ADR 0003). No repair workflow is implied.
enum StorageFailure: Error, Equatable, Sendable, CaseIterable {
    case invalidLocation, inspectionFailed, unsafeStructure, protectionDrift

    var message: String {
        switch self {
        case .invalidLocation:
            "Guesthouse refused an invalid managed-storage location. Cancel and preserve existing storage."
        case .inspectionFailed:
            "Guesthouse could not inspect its storage protection. Cancel and preserve the folders and any unpublished work."
        case .unsafeStructure:
            "Guesthouse cannot safely use its storage hierarchy. Preserve the folders and linked destinations; they may contain unpublished work. Cancel before changing anything."
        case .protectionDrift:
            "Guesthouse storage is no longer private. Cancel and leave its contents in place; they may contain unpublished work."
        }
    }
    var recoveryActions: [RecoveryAction] { [.cancel] }
}

/// Read-only checks adapted from #70/#88 for MVP-PLAN.md §§3 and 9. These are point-in-time
/// observations, NOT durable authority against concurrent namespace changes. Only runtime-
/// selected paths belong here. Preparation and every managed-component reuse must integrate
/// these checks before any production storage/VM operation is enabled.
enum StorageProtection {
    static func verify(_ url: URL) throws {
        let info = try structure(url)
        guard info.st_mode & 0o7777 == 0o700 else { throw StorageFailure.protectionDrift }
        try entries(at: try path(url), followLinks: false, expected: info) { _ in throw StorageFailure.protectionDrift }
    }

    /// Preparation may later repair leaf mode/ACL drift, but never an unsafe structure.
    @discardableResult static func structure(_ url: URL) throws -> stat {
        let name = try path(url)
        var info = stat()
        guard lstat(name, &info) == 0 else { throw StorageFailure.inspectionFailed }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw StorageFailure.unsafeStructure
        }
        try ancestors(from: parent(name))
        return info
    }

    /// Find the existing prefix before creation; missing suffixes never authorize mutation.
    static func existingAncestors(of url: URL) throws {
        var candidate = parent(try path(url))
        while true {
            var info = stat()
            if lstat(candidate, &info) == 0 { try ancestors(from: candidate); return }
            guard [ENOENT, ENOTDIR, ELOOP].contains(errno), candidate != "/" else {
                throw StorageFailure.inspectionFailed
            }
            candidate = parent(candidate)
        }
    }

    static func path(_ url: URL) throws -> String {
        var name = url.path(percentEncoded: false)
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, name.hasPrefix("/"),
              !name.utf8.contains(0), name.utf8.count < Int(PATH_MAX),
              !name.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw StorageFailure.invalidLocation
        }
        // A directory URL retains its trailing slash in this decoded representation. POSIX
        // would follow the final symlink for "link/", even with lstat/O_NOFOLLOW. Inspect the
        // entry itself instead, without resolving links or normalizing away rejected dots.
        while name.count > 1 && name.hasSuffix("/") { name.removeLast() }
        return name
    }
    private static func parent(_ path: String) -> String {
        let value = (path as NSString).deletingLastPathComponent
        return value.isEmpty ? "/" : value
    }
    private static func ancestors(from start: String) throws {
        var visited: Set<String> = []
        try walk(start, visited: &visited)
        guard let resolved = realpath(start, nil) else { throw StorageFailure.inspectionFailed }
        defer { free(resolved) }
        // Lexical checks alone miss the parents that control a symlink's target.
        try walk(String(cString: resolved), visited: &visited)
    }
    private static func walk(_ start: String, visited: inout Set<String>) throws {
        var candidate = start
        while true {
            if visited.insert(candidate).inserted { try ancestor(candidate) }
            if candidate == "/" { return }
            candidate = parent(candidate)
        }
    }
    private static func ancestor(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw StorageFailure.inspectionFailed }
        if info.st_mode & S_IFMT == S_IFLNK {
            // In a sticky parent, the link's owner may replace it regardless of its target.
            guard mayHoldEntry(owner: info.st_uid) else { throw StorageFailure.unsafeStructure }
            guard stat(path, &info) == 0 else { throw StorageFailure.unsafeStructure }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, mayHoldEntry(owner: info.st_uid),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 || info.st_mode & S_ISVTX != 0 else {
            throw StorageFailure.unsafeStructure
        }
        try entries(at: path, followLinks: true, expected: info) { entry in
            var tag = acl_tag_t(0)
            guard acl_get_tag_type(entry, &tag) == 0 else { throw StorageFailure.inspectionFailed }
            if tag == ACL_EXTENDED_DENY { return }
            guard tag == ACL_EXTENDED_ALLOW else { throw StorageFailure.inspectionFailed }
            if try grantsReplacement(entry), !isCurrentUser(entry) { throw StorageFailure.unsafeStructure }
        }
    }
    static func mayHoldEntry(owner: uid_t) -> Bool { owner == getuid() || owner == 0 }

    /// The SDK's acl_get_entry(3) specifies -1/EINVAL for exhaustion. Other failures are not
    /// an empty list. This is separate from absent metadata in a successful statx snapshot.
    static func enumerationFinished(result: Int32, error: Int32) -> Bool { result == -1 && error == EINVAL }
    private static func entries(at path: String, followLinks: Bool, expected: stat, visit: (acl_entry_t) throws -> Void) throws {
        // Apple's acl_get_file conflates lookup ENOENT with absent FILESEC_ACL metadata.
        // Query presence only AFTER a successful statx; never turn a lookup error into "none".
        // Evidence: apple-oss-distributions/Libc 71bbe350, acl_file.c + filesec.c + statx_np.c.
        guard let security = filesec_init() else { throw StorageFailure.inspectionFailed }
        defer { filesec_free(security) }
        var current = stat(), present: Int32 = 0
        var owner = uid_t(0), mode = mode_t(0)
        let result = followLinks ? statx_np(path, &current, security) : lstatx_np(path, &current, security)
        guard result == 0, current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
              current.st_uid == expected.st_uid, current.st_mode == expected.st_mode,
              filesec_get_property(security, FILESEC_OWNER, &owner) == 0, owner == current.st_uid,
              filesec_get_property(security, FILESEC_MODE, &mode) == 0, mode == current.st_mode,
              filesec_query_property(security, FILESEC_ACL, &present) == 0 else { throw StorageFailure.inspectionFailed }
        guard present != 0 else { return }
        var value: acl_t?
        guard filesec_get_property(security, FILESEC_ACL, &value) == 0, let acl = value else { throw StorageFailure.inspectionFailed }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var position = ACL_FIRST_ENTRY.rawValue
        while true {
            var entry: acl_entry_t?
            errno = 0
            let result = acl_get_entry(acl, position, &entry), error = errno
            if enumerationFinished(result: result, error: error) { return }
            guard result == 0, let entry else { throw StorageFailure.inspectionFailed }
            try visit(entry)
            position = ACL_NEXT_ENTRY.rawValue
        }
    }
    private static let replacementRights: [acl_perm_t] = [
        ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD, ACL_DELETE,
        ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
    ]
    private static func grantsReplacement(_ entry: acl_entry_t) throws -> Bool {
        var permissions: acl_permset_t?
        guard acl_get_permset(entry, &permissions) == 0, let permissions else { throw StorageFailure.inspectionFailed }
        var grants = false
        for right in replacementRights {
            let result = acl_get_perm_np(permissions, right)
            guard result == 0 || result == 1 else { throw StorageFailure.inspectionFailed }
            grants = grants || result == 1
        }
        return grants
    }
    private static func isCurrentUser(_ entry: acl_entry_t) -> Bool {
        guard let qualifier = acl_get_qualifier(entry) else { return false }
        defer { acl_free(qualifier) }
        var identifier = uid_t(0), kind = Int32(0)
        guard mbr_uuid_to_id(qualifier.assumingMemoryBound(to: UInt8.self), &identifier, &kind) == 0 else { return false }
        return kind == ID_TYPE_UID && identifier == getuid()
    }
}
