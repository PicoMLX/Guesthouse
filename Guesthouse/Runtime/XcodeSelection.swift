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

    enum Outcome {
        case canceled
        case handoff(FileHandoff)
        /// The panel returned a selection but no bookmark could be made for it: exactly the
        /// failure gate #34 exists to diagnose, so it is named, never reported as a cancel.
        case bookmarkFailed(String)
    }

    /// Presents the open panel and reports what happened.
    @MainActor
    static func chooseXcode() -> Outcome {
        let panel = NSOpenPanel()
        panel.title = "Choose Xcode"
        panel.message = "Choose the Xcode application to copy into the development Mac."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return .canceled }
        do {
            return .handoff(try handoff(for: url))
        } catch {
            return .bookmarkFailed(GuesthouseError.sanitize((error as NSError).localizedDescription, limit: 160))
        }
    }

    static func handoff(for url: URL) throws -> FileHandoff {
        // The panel grants read access only, which is all the app's
        // `files.user-selected.read-only` entitlement allows. A plain security scope asks for
        // read and write, exceeds that grant, and the bookmark is then refused for a selection
        // that was perfectly valid.
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        return FileHandoff(kind: .securityScopedBookmark(bookmark), displayName: url.lastPathComponent, expectedBundleIdentifier: expectedBundleIdentifier)
    }
}
