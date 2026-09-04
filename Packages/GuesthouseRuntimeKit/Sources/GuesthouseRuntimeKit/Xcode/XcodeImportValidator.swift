import Darwin
import Foundation
import GuesthouseCore

/// Turns a handed-off location into a validated `XcodeCandidate` without copying anything
/// (MVP-PLAN.md §2 step 5, §3 "Pass user-selected import/export access explicitly using
/// supported file-access handoff").
///
/// The handoff is the authority: a bookmark is resolved, never a bare path. The resolved
/// location is canonicalized, must be a directory bundle, must identify itself as Xcode, and
/// its version and build are read from `Info.plist` and `version.plist` without executing it.
public enum XcodeImportValidator {
    public static let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    /// Entries enumerated for the size estimate before giving up and reporting `nil`.
    public static let sizeEstimateEntryLimit = 400_000
    /// Larger metadata files are refused rather than loaded.
    public static let maximumMetadataBytes = 4 << 20

    /// Resolves the handoff to a location. Descriptors are received out of band by the
    /// service (gate #34 decides the transport); this validator accepts bookmarks now.
    /// A resolved handoff whose security scope, when the bookmark carries one, stays active
    /// until the value is released.
    public final class ResolvedLocation: Sendable {
        public let url: URL
        private let scoped: Bool

        init(url: URL, scoped: Bool) {
            self.url = url
            self.scoped = scoped
        }

        deinit {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Whether a bookmark must carry a usable security scope. Production requires it: a
    /// bookmark that resolves without one is not a grant from the sandboxed app. Tests, which
    /// make plain bookmarks, turn it off through `resolve(_:requireSecurityScope:)`.
    public static func resolve(_ handoff: FileHandoff, requireSecurityScope: Bool = true) throws(GuesthouseError) -> ResolvedLocation {
        switch handoff.kind {
        case .securityScopedBookmark(let data):
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL,
               url.startAccessingSecurityScopedResource() {
                return ResolvedLocation(url: url, scoped: true)
            }
            guard !requireSecurityScope,
                  let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL
            else {
                throw .xcodeSelectionRejected(.unresolvable)
            }
            return ResolvedLocation(url: url, scoped: false)
        case .fileDescriptor:
            throw .invalidRequest(.unsupportedOperation)
        }
    }

    /// Validates the location as an Xcode bundle and describes it.
    public static func candidate(at location: URL, expectedBundleIdentifier: String? = nil) throws(GuesthouseError) -> XcodeCandidate {
        guard location.isFileURL, !location.pathComponents.contains("..") else { throw .invalidRequest(.pathEscapesAllowedRoot) }
        let resolved = location.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue,
              resolved.pathExtension == "app"
        else { throw .xcodeSelectionRejected(.notAnApplication) }

        guard let info = try plist(resolved.appending(path: "Contents/Info.plist"), within: resolved) else { throw .xcodeSelectionRejected(.notAnApplication) }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == xcodeBundleIdentifier, identifier == (expectedBundleIdentifier ?? identifier) else {
            throw .xcodeSelectionRejected(.notXcode)
        }
        // Missing host metadata is a selection problem on this Mac, never a guest tool problem.
        guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        let versionPlist = try plist(resolved.appending(path: "Contents/version.plist"), within: resolved) ?? [:]
        guard let build = (versionPlist["ProductBuildVersion"] as? String) ?? (info["DTXcodeBuild"] as? String), !build.isEmpty else {
            throw .xcodeSelectionRejected(.metadataUnreadable)
        }
        // Metadata that sanitizes to nothing was not usable metadata.
        let safeVersion = GuesthouseError.sanitize(version), safeBuild = GuesthouseError.sanitize(build)
        guard !safeVersion.isEmpty, !safeBuild.isEmpty else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        return XcodeCandidate(
            version: safeVersion,
            build: safeBuild,
            path: resolved.path,
            sizeEstimateBytes: estimateSize(of: resolved)
        )
    }

    /// Allocated bytes under the bundle, or `nil` when the entry limit was reached. Every
    /// enumerated entry counts toward the limit, whatever it is, so a hostile tree cannot keep
    /// the runtime walking.
    public static func estimateSize(of url: URL) -> UInt64? {
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in failed = true; return true }
        ) else { return nil }
        var total: UInt64 = 0
        var entries = 0
        for case let item as URL in enumerator {
            entries += 1
            if entries > sizeEstimateEntryLimit { return nil }
            guard let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
                // An entry that cannot be read is not zero bytes: a partial sum would present
                // a definite estimate for a bundle nobody could measure.
                failed = true
                continue
            }
            guard values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return failed ? nil : total
    }

    /// A metadata file is read only if it is a regular file of bounded size whose real path,
    /// every ancestor resolved, still lies inside the bundle (a `Contents` link elsewhere
    /// would otherwise let a wrapper folder pass as Xcode).
    private static func plist(_ url: URL, within bundle: URL) throws(GuesthouseError) -> [String: Any]? {
        let real = url.standardizedFileURL.resolvingSymlinksInPath()
        guard real.path.hasPrefix(bundle.path + "/") else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        // The file is opened once, without following a link, and then checked and read through
        // that same descriptor: nothing can be swapped in between the check and the read.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            // Nothing there at all says the bundle has the wrong shape; a file that exists but
            // will not open (a link, a permissions problem) is metadata that cannot be read,
            // and the two failures need different advice.
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw .xcodeSelectionRejected(.metadataUnreadable)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        guard info.st_size <= maximumMetadataBytes else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        guard let data = try? handle.readToEnd(),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw .xcodeSelectionRejected(.metadataUnreadable) }
        return object
    }
}
