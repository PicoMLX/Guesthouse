import Darwin
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
    public static func defaultRoot() throws -> URL {
        do {
            return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
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

    /// The VM store, for `TART_HOME`.
    public var tartHome: URL { url(for: .vms) }

    /// The explicit environment for every Tart invocation: only `TART_HOME`. `PATH` and the
    /// rest of the service's environment are deliberately absent.
    public func environmentForTart() -> [String: String] {
        ["TART_HOME": tartHome.path]
    }

    /// Lume's VM and configuration locations are both explicit. Telemetry and update checks
    /// stay off during the spike, and no host `HOME` or `PATH` is inherited.
    public func environmentForLume() -> [String: String] {
        [
            "LUME_TELEMETRY_ENABLED": "false",
            "LUME_UPDATE_CHECK": "false",
            "TMPDIR": url(for: .staging).path,
            "XDG_CONFIG_HOME": url(for: .lumeConfiguration).path,
        ]
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
    /// with repairable permissions or ACLs, but links and foreign-owned objects are never changed.
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
        return info
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
