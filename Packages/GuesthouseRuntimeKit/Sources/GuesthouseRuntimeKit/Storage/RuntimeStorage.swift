import Foundation

/// The runtime-managed directory tree under the service user's Application Support
/// (MVP-PLAN.md §3, "Local storage"): runtime downloads, VM data, maintenance SSH files,
/// operation state, and diagnostics, each in its own subdirectory with restrictive
/// permissions. The sandboxed GUI never sees these paths directly; it reads metadata over
/// XPC, and it can never supply the root.
public struct RuntimeStorage: Sendable {
    public enum Subdirectory: String, CaseIterable, Sendable {
        /// Verified Tart bundles, one folder per version.
        case runtime
        /// The VM store. This is `TART_HOME`, so lifecycle actions can never reach unrelated
        /// Tart machines in the user's default `~/.tart`.
        case vms
        /// `StateStore` root: snapshot and journal.
        case state
        /// Maintenance SSH identities and known-hosts files. Never exported to the user's
        /// discoverable SSH configuration.
        case sshMaintenance = "ssh/maintenance"
        /// Temporary staging for imports and extraction; safe to discard when idle.
        case staging
        /// In-progress and verified downloads.
        case downloads
        /// Redacted logs and exports.
        case diagnostics

        /// Large, regenerable, or purely transient content that Time Machine should skip.
        public var isExcludedFromBackup: Bool {
            switch self {
            case .vms, .staging, .downloads: true
            case .runtime, .state, .sshMaintenance, .diagnostics: false
            }
        }
    }

    public static let directoryPermissions = 0o700

    public let root: URL

    /// The default root for the service's user: `~/Library/Application Support/Guesthouse`.
    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Guesthouse")
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

    // MARK: - Verification

    private static func prepare(_ url: URL, backupExcluded: Bool, createIntermediates: Bool) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: [.posixPermissions: directoryPermissions])
        }
        try verify(url)
        try manager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: url.path)
        if backupExcluded {
            var mutable = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutable.setResourceValues(values)
        }
    }

    static func verify(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileResourceIdentifierKey])
        if values.isSymbolicLink == true {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "symbolic link")
        }
        guard values.isDirectory == true else {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "not a directory")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let owner = attributes[.ownerAccountID] as? UInt32, owner != getuid() {
            throw RuntimeStorageError.insecureDirectory(path: url.path, reason: "owned by another user")
        }
    }
}

public enum RuntimeStorageError: Error, Hashable, Sendable {
    case insecureDirectory(path: String, reason: String)
}
