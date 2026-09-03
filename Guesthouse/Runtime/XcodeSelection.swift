import AppKit
import GuesthouseCore
import UniformTypeIdentifiers

/// Lets the user pick an Xcode application bundle and turns the selection into a
/// `FileHandoff` for the runtime service (MVP-PLAN.md §2 step 5, §3 file-access handoff).
///
/// The handoff carries a bookmark of the selection, never a bare path as authority; the
/// service resolves it and validates the bundle itself. Whether the embedded, unsandboxed
/// service can resolve a bookmark made by the sandboxed app is exactly what gate #34 proves.
enum XcodeSelection {
    static let expectedBundleIdentifier = "com.apple.dt.Xcode"

    /// Presents the open panel and returns a handoff, or `nil` if the user canceled.
    @MainActor
    static func chooseXcode() -> FileHandoff? {
        let panel = NSOpenPanel()
        panel.title = "Choose Xcode"
        panel.message = "Choose the Xcode application to copy into the development Mac."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return handoff(for: url)
    }

    static func handoff(for url: URL) -> FileHandoff? {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        return FileHandoff(kind: .securityScopedBookmark(bookmark), displayName: url.lastPathComponent, expectedBundleIdentifier: expectedBundleIdentifier)
    }
}
