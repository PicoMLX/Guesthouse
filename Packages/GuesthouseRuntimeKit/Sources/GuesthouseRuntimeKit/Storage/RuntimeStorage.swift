import Darwin
import Foundation

/// Service-only storage layout migrated from #70/#88 (MVP-PLAN.md §§3 and 9). No GUI-supplied
/// root or provider environment adapter. Preparation is explicit; reuse only checks and never
/// silently repairs. Paths remain point-in-time observations, not permanent filesystem leases.
struct RuntimeStorage: Sendable {
    enum Area: String, CaseIterable, Sendable {
        case runtime, vms, state, staging, downloads, diagnostics
        case sshMaintenance = "ssh/maintenance"

        // A VM disk may be the only copy of unpublished work. Eligibility is NOT a verified backup.
        var excludedFromBackup: Bool { self == .staging || self == .downloads }
    }
    private let root: URL
    typealias BackupWriter = @Sendable (URL, Bool) throws -> Void

    init() throws { try self.init(root: Self.defaultRoot()) }
    init(root: URL) throws { try self.init(root: root, backup: Self.writeBackupExclusion) }

    /// Runtime-only injection for isolated fixtures; never exposed in an XPC request.
    init(root: URL, backup: BackupWriter) throws {
        // Use the same validated, trailing-separator-free spelling for inspection AND writes.
        let root = URL(fileURLWithPath: try StorageProtection.path(root), isDirectory: false)
        try StorageProtection.existingAncestors(of: root) // Validate the original decoded path first.
        self.root = root
        // Inspect the entire existing managed layout BEFORE changing any protection or creating
        // siblings. A link/file/unsafe ancestor anywhere causes a preservation-first refusal.
        let layout = [(root, false)] + Self.components(root: root)
        for (url, _) in layout { try Self.preflight(url) }
        let preparation = try Self.missingParents(of: root).map { ($0, false) } + layout
        for (url, excluded) in preparation { try Self.prepare(url, excluded: excluded, backup: backup) }
        for (url, excluded) in preparation { try Self.verify(url, excluded: excluded) }
    }

    /// Resolution only. No Application Support directory is created before ancestry checks.
    static func defaultRoot() throws -> URL {
        do {
            return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false).appending(path: "Guesthouse")
        } catch { throw StorageFailure.inspectionFailed }
    }

    /// Each use rechecks the root, every managed intermediate, and the selected leaf, including
    /// backup-policy drift. Returning this URL does not authorize arbitrary child paths or writes.
    func location(for area: Area) throws -> URL {
        try Self.verify(root, excluded: false)
        var result = root
        let parts = area.rawValue.split(separator: "/")
        for (index, part) in parts.enumerated() {
            result.append(path: String(part))
            try Self.verify(result, excluded: index == parts.count - 1 && area.excludedFromBackup)
        }
        return result
    }

    private static func components(root: URL) -> [(URL, Bool)] {
        var result: [(URL, Bool)] = []
        for area in Area.allCases {
            var url = root
            let parts = area.rawValue.split(separator: "/")
            for (index, part) in parts.enumerated() {
                url.append(path: String(part))
                result.append((url, index == parts.count - 1 && area.excludedFromBackup))
            }
        }
        return result
    }

    private static func preflight(_ url: URL) throws {
        try StorageProtection.existingAncestors(of: url)
        var info = stat()
        if lstat(url.path(percentEncoded: false), &info) == 0 {
            try StorageProtection.structure(url)
        } else if errno != ENOENT { throw StorageFailure.inspectionFailed }
    }

    private static func missingParents(of url: URL) throws -> [URL] {
        var missing: [URL] = [], candidate = url.deletingLastPathComponent()
        while true {
            var info = stat()
            if lstat(candidate.path(percentEncoded: false), &info) == 0 { return missing.reversed() }
            guard errno == ENOENT, candidate.path != "/" else { throw StorageFailure.inspectionFailed }
            missing.append(candidate)
            candidate.deleteLastPathComponent()
        }
    }

    private static func prepare(_ url: URL, excluded: Bool, backup: BackupWriter) throws {
        try preflight(url)
        let path = url.path(percentEncoded: false)
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw StorageFailure.inspectionFailed }
            // One component at a time, private from birth; never recursively traverse an
            // uninspected missing suffix. EEXIST still requires real-directory/owner checks.
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw StorageFailure.preparationFailed }
        }
        let expected = try StorageProtection.structure(url)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageFailure.inspectionFailed }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameIdentity(opened, expected), opened.st_mode == expected.st_mode else {
            throw StorageFailure.unsafeStructure
        }
        guard let empty = acl_init(0) else { throw StorageFailure.preparationFailed }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        // Mutate the inspected open directory, never chmod or set an ACL through a final link.
        guard fchmod(fd, 0o700) == 0, acl_set_fd(fd, empty) == 0 else { throw StorageFailure.preparationFailed }
        try verifyIdentity(url, expected: expected)
        try StorageProtection.verify(url)
        do { try backup(url, excluded) } catch { throw StorageFailure.preparationFailed }
        // Foundation's backup metadata API is path-based. Refuse a changed binding afterward;
        // this is not an atomic tree transaction or authority against hostile same-user races.
        try verifyIdentity(url, expected: expected)
        try verify(url, excluded: excluded)
    }

    private static func sameIdentity(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode & S_IFMT == S_IFDIR
    }
    private static func verifyIdentity(_ url: URL, expected: stat) throws {
        let current = try StorageProtection.structure(url)
        guard sameIdentity(current, expected) else { throw StorageFailure.unsafeStructure }
    }
    private static func verify(_ url: URL, excluded: Bool) throws {
        try StorageProtection.verify(url)
        // A fresh URL avoids Foundation's cached resource values masking subsequent drift.
        let fresh = URL(fileURLWithPath: url.path(percentEncoded: false), isDirectory: true)
        let actual: Bool?
        do { actual = try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup }
        catch { throw StorageFailure.inspectionFailed }
        guard actual == excluded else { throw StorageFailure.protectionDrift }
    }
    static func writeBackupExclusion(_ url: URL, _ excluded: Bool) throws {
        var fresh = URL(fileURLWithPath: url.path(percentEncoded: false), isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try fresh.setResourceValues(values)
    }
}
