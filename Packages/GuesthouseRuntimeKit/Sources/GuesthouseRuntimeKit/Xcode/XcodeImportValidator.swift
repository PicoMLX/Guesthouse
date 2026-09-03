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
    /// Files enumerated for the size estimate before giving up and reporting `nil`.
    public static let sizeEstimateFileLimit = 400_000

    /// Resolves the handoff to a location. Descriptors are received out of band by the
    /// service (gate #34 decides the transport); this validator accepts bookmarks now.
    public static func resolve(_ handoff: FileHandoff) throws(GuesthouseError) -> URL {
        switch handoff.kind {
        case .securityScopedBookmark(let data):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL else {
                throw .invalidRequest(.malformed)
            }
            return url
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
        else { throw .invalidRequest(.malformed) }

        guard let info = plist(resolved.appending(path: "Contents/Info.plist")) else { throw .invalidRequest(.malformed) }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == xcodeBundleIdentifier, identifier == (expectedBundleIdentifier ?? identifier) else {
            throw .invalidRequest(.malformed)
        }
        guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { throw .xcodeComponentsIncomplete(missing: ["Info.plist version"]) }
        let versionPlist = plist(resolved.appending(path: "Contents/version.plist")) ?? [:]
        guard let build = (versionPlist["ProductBuildVersion"] as? String) ?? (info["DTXcodeBuild"] as? String), !build.isEmpty else {
            throw .xcodeComponentsIncomplete(missing: ["ProductBuildVersion"])
        }
        return XcodeCandidate(
            version: GuesthouseError.sanitize(version),
            build: GuesthouseError.sanitize(build),
            path: resolved.path,
            sizeEstimateBytes: estimateSize(of: resolved)
        )
    }

    /// Allocated bytes under the bundle, or `nil` when the file limit was reached.
    public static func estimateSize(of url: URL) -> UInt64? {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: []) else { return nil }
        var total: UInt64 = 0
        var files = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
            files += 1
            if files >= sizeEstimateFileLimit { return nil }
        }
        return total
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return object
    }
}
