import Darwin
// Resolves an access control entry's qualifier to an account identifier. `membership` is an
// explicit submodule, so importing `Darwin` alone does not bring `mbr_uuid_to_id` into scope.
import Darwin.membership
import Foundation
import GuesthouseCore

/// The runtime-managed directory tree under the service user's Application Support
/// (MVP-PLAN.md §3, "Local storage"): runtime downloads, VM data, maintenance SSH files,
/// operation state, and diagnostics, each in its own subdirectory with restrictive
/// permissions. The sandboxed GUI never sees these paths directly; it reads metadata over
/// XPC, and it can never supply the root.
public struct RuntimeStorage: Sendable {
    public enum Subdirectory: String, CaseIterable, Sendable {
        /// Verified VM runtime bundles, one folder per version.
        case runtime
        /// The VM store. Every provider receives it explicitly, so lifecycle actions can
        /// never reach unrelated machines in a provider's default store.
        case vms
        /// `StateStore` root: snapshot and journal.
        case state
        /// Lume writes configuration even when a direct VM store is supplied. Pin its XDG
        /// root here so a probe cannot create or read the user's default `~/.lume` state.
        case lumeConfiguration = "state/lume-xdg"
        /// Maintenance SSH identities and known-hosts files. Never exported to the user's
        /// discoverable SSH configuration.
        case sshMaintenance = "ssh/maintenance"
        /// Temporary staging for imports and extraction; safe to discard when idle.
        case staging
        /// In-progress and verified downloads.
        case downloads
        /// Redacted logs and exports.
        case diagnostics

        /// Only regenerable or transient content is excluded from Time Machine. The VM store
        /// is not: a guest's disk can be the only copy of unpublished work (MVP-PLAN.md §9,
        /// "Protect unpublished work"), so it stays eligible until a proven export mechanism
        /// exists, even though it is large.
        public var isExcludedFromBackup: Bool {
            switch self {
            case .staging, .downloads: true
            case .vms, .runtime, .state, .lumeConfiguration, .sshMaintenance, .diagnostics: false
            }
        }
    }

    public static let directoryPermissions = 0o700

    public let root: URL

    /// The default root for the service's user: `~/Library/Application Support/Guesthouse`.
    ///
    /// The location is only resolved here, never created: `create: true` would make
    /// Application Support before anything has looked at the directories above it, and
    /// `init(root:)` would then refuse a hierarchy it had already added to — the opposite of
    /// the preservation MVP-PLAN.md §3 asks for. `prepare` creates what is missing, `0700`,
    /// after the ancestors it will live under have been verified.
    public static func defaultRoot() throws -> URL {
        do {
            return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appending(path: "Guesthouse")
        } catch {
            throw RuntimeStorageError.unwritable(path: "~/Library/Application Support", reason: SanitizedText(error.localizedDescription, limit: 120))
        }
    }

    /// Prepares the whole tree. Every directory is created `0700` if missing, and every
    /// existing one is verified to be a real directory owned by the current user, not a
    /// symbolic link; otherwise the storage refuses to operate.
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try Self.prepare(self.root, backupExcluded: false, createIntermediates: true)
        for subdirectory in Subdirectory.allCases {
            // Prepare every intermediate component too, so `ssh/` is as restricted as `ssh/maintenance/`.
            var url = self.root
            let components = subdirectory.rawValue.split(separator: "/").map(String.init)
            for (index, component) in components.enumerated() {
                url.append(path: component)
                let isLeaf = index == components.count - 1
                try Self.prepare(url, backupExcluded: isLeaf && subdirectory.isExcludedFromBackup, createIntermediates: false)
            }
        }
    }

    public func url(for subdirectory: Subdirectory) -> URL {
        root.appending(path: subdirectory.rawValue)
    }

    /// The VM store's location. Use `environmentForTart()` before a Tart operation so the
    /// directory's current protection is checked before it becomes `TART_HOME`.
    public var tartHome: URL { url(for: .vms) }

    /// The explicit environment for every Tart invocation: only `TART_HOME`. `PATH` and the
    /// rest of the service's environment are deliberately absent. Revalidate on every call:
    /// this value may outlive the private directories that initialization prepared.
    public func environmentForTart() throws -> [String: String] {
        try Self.verify(root)
        try Self.verify(tartHome)
        return ["TART_HOME": tartHome.path]
    }

    /// Lume's configuration and temporary locations are explicit. Telemetry and update checks
    /// stay off during the spike, and no host `HOME` or `PATH` is inherited. VM lifecycle commands
    /// must separately pass `--storage` with `url(for: .vms)`; Lume has no VM-store environment key.
    public func environmentForLume() -> [String: String] {
        [
            "LUME_TELEMETRY_ENABLED": "false",
            "LUME_UPDATE_CHECK": "false",
            "TMPDIR": url(for: .staging).path,
            "XDG_CONFIG_HOME": url(for: .lumeConfiguration).path,
        ]
    }

    /// Revalidates every writable directory a Lume probe receives. Checking the `state` parent
    /// separately prevents an apparently valid `lume-xdg` leaf from being reached through a
    /// replaced intermediate link.
    func verifyLumeInvocationDirectories() throws {
        try Self.verify(root)
        try Self.verify(url(for: .runtime))
        try Self.verify(url(for: .state))
        try Self.verify(url(for: .lumeConfiguration))
        try Self.verify(url(for: .staging))
    }

    /// Stable identity for coordinating aliases that reach the same physical directory.
    /// Paths alone are insufficient on macOS (`/tmp` and `/private/tmp` are one example).
    struct CoordinationIdentity: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    /// A point-in-time filesystem identity for verified runtime files. Device and inode detect
    /// replacement; size plus nanosecond modification/status-change times also detect an
    /// unprivileged in-place write that keeps the same inode. This is a coherence signal, not a
    /// substitute for the full signature and digest verification performed at each launch.
    struct VerificationIdentity: Hashable, Sendable {
        let coordination: CoordinationIdentity
        let byteCount: off_t
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    func coordinationIdentity() throws -> CoordinationIdentity {
        try Self.verify(root)
        guard let identity = Self.fileIdentity(of: root) else {
            throw RuntimeStorageError.insecureDirectory(path: root.path, reason: "cannot be inspected")
        }
        return identity
    }

    static func fileIdentity(of url: URL) -> CoordinationIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return CoordinationIdentity(device: info.st_dev, inode: info.st_ino)
    }

    static func verificationIdentity(of url: URL) -> VerificationIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return VerificationIdentity(
            coordination: CoordinationIdentity(device: info.st_dev, inode: info.st_ino),
            byteCount: info.st_size,
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    // MARK: - Verification

    private static func prepare(_ url: URL, backupExcluded: Bool, createIntermediates: Bool) throws {
        let manager = FileManager.default
        var info = stat()
        let inspectionStatus = lstat(url.path, &info)
        if inspectionStatus != 0 {
            let inspectionError = errno
            guard isPathTraversalFailure(inspectionError) else {
                throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "cannot be inspected")
            }
            try refuseUnsafeExistingAncestor(of: url)
            // Nothing is created inside a hierarchy that will then be refused. `verify` checks
            // the ancestors below, but by then the refusal has already made the host change it
            // was refusing to make: initialization would leave a new directory inside a tree it
            // goes on to call untrusted, where MVP-PLAN.md §3 asks a refusal to preserve.
            try verifyExistingAncestors(of: url)
            do {
                try manager.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: [.posixPermissions: directoryPermissions])
            } catch let creationError {
                // A path may have appeared between inspection and creation. Classify an
                // object that now exists before translating the creation failure, so a
                // dangling link can never acquire writable-storage recovery actions.
                if lstat(url.path, &info) == 0 {
                    _ = try verifyStructure(url)
                } else {
                    let retryInspectionError = errno
                    if isPathTraversalFailure(retryInspectionError) {
                        try refuseUnsafeExistingAncestor(of: url)
                    }
                    throw RuntimeStorageError.unwritable(path: url.path, reason: SanitizedText(creationError.localizedDescription, limit: 120))
                }
            }
        }
        // Unlike FileManager.fileExists, lstat observes a symbolic link even when its target
        // is absent. Verify before changing permissions or backup metadata so every link is
        // refused with preservation-first guidance.
        _ = try verifyStructure(url)
        do {
            try manager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: url.path)
        } catch {
            throw RuntimeStorageError.unwritable(path: url.path, reason: SanitizedText(error.localizedDescription, limit: 120))
        }
        try removeAccessControlEntries(url)
        // Always written, so a stale exclusion on a directory that must be backed up is cleared.
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = backupExcluded
        do {
            try mutable.setResourceValues(values)
        } catch {
            throw RuntimeStorageError.unwritable(path: url.path, reason: SanitizedText(error.localizedDescription, limit: 120))
        }
        // Do not assume the filesystem honored the requested protection. Re-read the final mode
        // and ACL state after every mutation and fail closed if either is still permissive.
        try verify(url)
    }

    /// If a missing suffix sits below a path component that cannot resolve to a directory,
    /// report that existing component as structural storage instead of blaming writability.
    /// Valid ancestor links remain supported (for example, macOS's `/tmp` link).
    private static func refuseUnsafeExistingAncestor(of url: URL) throws {
        var candidate = url.deletingLastPathComponent()
        while true {
            var linkInfo = stat()
            if lstat(candidate.path, &linkInfo) == 0 {
                switch linkInfo.st_mode & S_IFMT {
                case S_IFDIR:
                    return
                case S_IFLNK:
                    var targetInfo = stat()
                    guard stat(candidate.path, &targetInfo) == 0 else {
                        let targetError = errno
                        let reason = isPathTraversalFailure(targetError) ? "dangling symbolic link" : "cannot be inspected"
                        throw RuntimeStorageError.insecureDirectory(path: candidate.path, reason: reason)
                    }
                    guard targetInfo.st_mode & S_IFMT == S_IFDIR else {
                        throw RuntimeStorageError.insecureDirectory(path: candidate.path, reason: "not a directory")
                    }
                    return
                default:
                    throw RuntimeStorageError.insecureDirectory(path: candidate.path, reason: "not a directory")
                }
            }

            let inspectionError = errno
            guard isPathTraversalFailure(inspectionError) else {
                throw RuntimeStorageError.insecureDirectory(path: candidate.path, reason: "cannot be inspected")
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "cannot be inspected")
            }
            candidate = parent
        }
    }

    private static func isPathTraversalFailure(_ code: Int32) -> Bool {
        code == ENOENT || code == ENOTDIR || code == ELOOP
    }

    /// A private directory owned by the current user, not a link. This is the strict check used
    /// after initialization and whenever runtime code re-enters the storage tree.
    static func verify(_ url: URL) throws {
        let info = try verifyStructure(url)
        guard info.st_mode & mode_t(0o7777) == mode_t(directoryPermissions) else {
            throw RuntimeStorageError.protectionDrift(path: url.path, reason: "permissions are not 0700")
        }
        guard try !hasAccessControlEntries(url) else {
            throw RuntimeStorageError.protectionDrift(path: url.path, reason: "carries access control entries")
        }
    }

    /// Structural preflight used only while preparing storage. Existing directories may start
    /// with repairable permissions or ACLs, but links, foreign-owned objects, and unsafe
    /// ancestors are refused before any change is made.
    private static func verifyStructure(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "cannot be inspected")
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "symbolic link")
        case S_IFDIR: break
        default: throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "not a directory")
        }
        guard info.st_uid == getuid() else {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "owned by another user")
        }
        try verifyAncestors(of: url)
        return info
    }

    /// A `0700` directory is only as private as the directories above it: another local
    /// account that can write to an ancestor can rename this one away and put its own
    /// directory in its place, and everything written afterwards would go there.
    ///
    /// Two chains are walked. The lexical one is what the caller named. Following a symbolic
    /// link in it validates the link's target but leaves the target's own parents unseen, and
    /// whoever can write to those can rename the target away just the same; resolving the
    /// deepest ancestor resolves every component above it, so the second walk covers the whole
    /// real chain in one pass.
    static func verifyAncestors(of url: URL) throws {
        let lexicalParent = (url.standardizedFileURL.path as NSString).deletingLastPathComponent
        guard !lexicalParent.isEmpty else { return }
        var verified: Set<String> = []
        try verifyAncestorChain(from: lexicalParent, verified: &verified)
        let canonicalParent = try canonicalPath(of: lexicalParent)
        if canonicalParent != lexicalParent {
            try verifyAncestorChain(from: canonicalParent, verified: &verified)
        }
    }

    /// The same checks, for a directory that does not exist yet: they run on the ancestors that
    /// already do, before anything is created.
    static func verifyExistingAncestors(of url: URL) throws {
        guard let start = deepestExistingAncestor(of: url) else { return }
        var verified: Set<String> = []
        try verifyAncestorChain(from: start, verified: &verified)
        let canonical = try canonicalPath(of: start)
        if canonical != start {
            try verifyAncestorChain(from: canonical, verified: &verified)
        }
    }

    /// The deepest ancestor of `url` that is there to be checked. `nil` when none is, which
    /// only happens for a path with no existing ancestor at all.
    private static func deepestExistingAncestor(of url: URL) -> String? {
        var candidate = (url.standardizedFileURL.path as NSString).deletingLastPathComponent
        while !candidate.isEmpty {
            var info = stat()
            if lstat(candidate, &info) == 0 { return candidate }
            if candidate == "/" { return nil }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func verifyAncestorChain(from start: String, verified: inout Set<String>) throws {
        var candidate = start
        while !candidate.isEmpty {
            if verified.insert(candidate).inserted {
                try verifyAncestor(candidate)
            }
            if candidate == "/" { return }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }

    /// Every ancestor must be owned by this user or by root, must not be writable by anyone
    /// else unless it is sticky (the rule that makes `/tmp` safe), and must not hand the same
    /// power to another principal through an access control entry.
    private static func verifyAncestor(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw RuntimeStorageError.insecureDirectory(path: path, reason: "cannot be inspected")
        }
        if info.st_mode & S_IFMT == S_IFLNK {
            // The link entry is checked before it is followed. Where it stands today may be a
            // directory of ours, but in a shared sticky folder such as `/tmp` its owner is the
            // one who may replace it, and replacing it redirects everything written afterwards.
            guard mayHoldStorageEntry(owner: info.st_uid) else {
                throw RuntimeStorageError.insecureDirectory(path: path, reason: "a containing folder is reached through a link another user can replace")
            }
            guard stat(path, &info) == 0 else {
                throw RuntimeStorageError.insecureDirectory(path: path, reason: "dangling symbolic link")
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw RuntimeStorageError.insecureDirectory(path: path, reason: "not a directory")
        }
        guard mayHoldStorageEntry(owner: info.st_uid) else {
            throw RuntimeStorageError.insecureDirectory(path: path, reason: "a containing folder is owned by another user")
        }
        let sharedWrite = info.st_mode & (S_IWGRP | S_IWOTH)
        let sticky = info.st_mode & S_ISVTX
        guard sharedWrite == 0 || sticky != 0 else {
            throw RuntimeStorageError.insecureDirectory(path: path, reason: "a containing folder can be changed by other users")
        }
        try verifyAncestorAccessControl(path)
    }

    /// Who may hold a directory entry on the way to storage: this user, or the system. Anyone
    /// else owns a name they can replace, whatever it points at now.
    static func mayHoldStorageEntry(owner: uid_t) -> Bool {
        owner == getuid() || owner == 0
    }

    /// The fully resolved path, so a symbolic link anywhere in the chain is walked as the
    /// directory it really is. An ancestor of an existing directory always resolves; a failure
    /// means the tree changed underneath us or cannot be traversed, and is refused.
    private static func canonicalPath(of path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw RuntimeStorageError.insecureDirectory(path: path, reason: "cannot be inspected")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The directory rights that let a principal replace an ancestor or take it over: adding,
    /// renaming or removing entries in it, deleting it, or rewriting the metadata that decides
    /// who may do those things.
    private static let replacementRights: [acl_perm_t] = [
        ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD, ACL_DELETE,
        ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
    ]

    /// The POSIX mode is not the whole story: an ancestor at `0755` whose access control list
    /// grants another principal the right to add or delete entries is still replaceable.
    /// Ordinary Macs carry harmless entries — a home folder's "everyone deny delete", for one —
    /// so entries are inspected rather than refused wholesale: only a grant naming someone
    /// other than this user is a refusal. Deny entries take nothing away from us and are kept.
    private static func verifyAncestorAccessControl(_ path: String) throws {
        // Ancestor symbolic links are already followed by `stat`, so follow them here too: the
        // rights that matter are the ones on the directory the chain actually reaches.
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw RuntimeStorageError.insecureDirectory(path: path, reason: "access control entries could not be inspected")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var position = ACL_FIRST_ENTRY.rawValue
        while true {
            errno = 0
            let status = acl_get_entry(acl, position, &entry)
            guard status == 0 else {
                // The enumeration ends by failing with the empty-or-exhausted code. Stopping on
                // anything else would leave the rest of the list unread, and an unread entry may
                // be the one that grants somebody else the right to replace this ancestor.
                guard aclEnumerationFinished(errno) else {
                    throw RuntimeStorageError.insecureDirectory(path: path, reason: "access control entries could not be inspected")
                }
                return
            }
            position = ACL_NEXT_ENTRY.rawValue
            guard let current = entry else {
                throw RuntimeStorageError.insecureDirectory(path: path, reason: "access control entries could not be inspected")
            }
            var tag = acl_tag_t(0)
            guard acl_get_tag_type(current, &tag) == 0 else {
                throw RuntimeStorageError.insecureDirectory(path: path, reason: "access control entries could not be inspected")
            }
            if tag == ACL_EXTENDED_DENY { continue }
            guard try grantsReplacementRights(current, path: path), !isCurrentUser(current) else { continue }
            throw RuntimeStorageError.insecureDirectory(path: path, reason: "a containing folder grants another user the right to change it")
        }
    }

    /// Whether an entry enumeration that stopped had actually reached the end of the list.
    /// Darwin reports an empty or exhausted list by failing the call with `EINVAL`; `ENOENT`
    /// is the same answer for a path that carries no list at all. Every other code means
    /// entries were left unread.
    static func aclEnumerationFinished(_ code: Int32) -> Bool {
        code == EINVAL || code == ENOENT
    }

    private static func grantsReplacementRights(_ entry: acl_entry_t, path: String) throws -> Bool {
        var permissions: acl_permset_t?
        guard acl_get_permset(entry, &permissions) == 0, let permissions else {
            throw RuntimeStorageError.insecureDirectory(path: path, reason: "access control entries could not be inspected")
        }
        // `acl_get_perm_np` answers 1 for granted and -1 for an unreadable permission; both
        // count as granted, so an entry we cannot fully read is never waved through.
        return replacementRights.contains { acl_get_perm_np(permissions, $0) != 0 }
    }

    /// Whether the entry names this user's account. A qualifier that resolves to a group, or
    /// that cannot be resolved to an account at all, is deliberately not this user: a group
    /// grant reaches every other member of it.
    private static func isCurrentUser(_ entry: acl_entry_t) -> Bool {
        guard let qualifier = acl_get_qualifier(entry) else { return false }
        defer { acl_free(qualifier) }
        var identifier = uid_t(0)
        var kind = Int32(0)
        guard mbr_uuid_to_id(qualifier.assumingMemoryBound(to: UInt8.self), &identifier, &kind) == 0 else { return false }
        return kind == ID_TYPE_UID && identifier == getuid()
    }

    /// POSIX mode `0700` does not remove access control entries an existing or inherited
    /// directory may carry. Any entries are removed, and the directory is refused if they
    /// cannot be.
    static func removeAccessControlEntries(_ url: URL) throws {
        guard try hasAccessControlEntries(url) else { return }
        guard let empty = acl_init(0) else {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "access control entries could not be removed")
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        guard acl_set_link_np(url.path, ACL_TYPE_EXTENDED, empty) == 0, try !hasAccessControlEntries(url) else {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "carries access control entries that could not be removed")
        }
    }

    /// Whether the directory carries access control entries. "No ACL" (`ENOENT`) is the only
    /// answer taken as none; any other failure to inspect is refused, never assumed clean.
    static func hasAccessControlEntries(_ url: URL) throws -> Bool {
        // `ENOENT` from the ACL call means "no ACL" only for a path that exists.
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "cannot be inspected")
        }
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "access control entries could not be inspected")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let status = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        if status == 0 { return true }
        // -1 with EINVAL means the list is empty; anything else is an inspection failure.
        guard errno == EINVAL || errno == 0 else {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "access control entries could not be inspected")
        }
        return false
    }
}

/// Storage failures block every runtime operation, so each names what happened and what the
/// user can do (AGENTS.md: every error carries a message and a recovery action).
public enum RuntimeStorageError: Error, Hashable, Sendable, LocalizedError {
    case protectionDrift(path: String, reason: String)
    case insecureDirectory(path: String, reason: String)
    case unwritable(path: String, reason: SanitizedText)

    public var userMessage: String {
        switch self {
        case .protectionDrift(let path, let reason):
            "Guesthouse stopped because its storage folder \(GuesthouseError.sanitize(path, limit: 200)) is no longer private (\(GuesthouseError.sanitize(reason, limit: 120))). Leave the folder and its contents in place—they may include unpublished work. Quit and reopen Guesthouse so it can restore the required protection, then try again."
        case .insecureDirectory(let path, let reason):
            "Guesthouse cannot safely use the item at its storage path \(GuesthouseError.sanitize(path, limit: 200)) (\(GuesthouseError.sanitize(reason, limit: 120))). Preserve the item and any linked destination exactly as they are; they may contain unpublished work. Cancel and inspect the path before changing anything."
        case .unwritable(let path, let reason):
            "Guesthouse cannot write to its storage folder \(GuesthouseError.sanitize(path, limit: 200)) (\(reason.value)). Leave the folder and its contents in place because they may contain unpublished work. Free disk space or restore write access, then try again."
        }
    }

    /// In preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .protectionDrift, .insecureDirectory: [.cancel]
        case .unwritable: [.freeDiskSpace, .retry, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}
