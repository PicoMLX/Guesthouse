import Darwin
import Foundation

extension RequestValidator {
    /// Shared name shape from #9: a whole lowercase UUID, never a guest-supplied display name.
    /// Matching this shape does NOT prove Guesthouse ownership or authorize lifecycle actions.
    public static func validateVMName(_ name: String) throws(RequestValidationError) {
        guard name.utf8.count == 47, name.hasPrefix("guesthouse-"),
              let uuid = UUID(uuidString: String(name.dropFirst(11))),
              name == "guesthouse-\(uuid.uuidString.lowercased())"
        else { throw .invalidVMName }
    }

    /// Snapshot containment sanity check retained from #58 (MVP-PLAN.md §3).
    /// The service supplies its trusted root. This does not confer sandbox permission, prove
    /// root ownership, or prevent filesystem races: actual access must use the runtime's
    /// independently validated bookmark/descriptor and race-safe managed-storage operations.
    public static func validateContainment(of candidate: URL, within root: URL) throws(RequestValidationError) -> URL {
        guard candidate.isFileURL, root.isFileURL else { throw .invalidPath }
        guard !candidate.pathComponents.contains("..") else { throw .pathEscapesRoot }
        guard !containsDanglingSymbolicLink(root, below: URL(fileURLWithPath: "/")) else { throw .pathEscapesRoot }
        let resolvedRoot = resolveThroughExistingAncestors(root)
        let resolvedCandidate = resolveThroughExistingAncestors(candidate)
        let rootComponents = resolvedRoot.pathComponents
        let candidateComponents = resolvedCandidate.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else { throw .pathEscapesRoot }
        // Check both spellings: the trusted root can itself be reached through an alias.
        guard !containsDanglingSymbolicLink(candidate, below: root),
              !containsDanglingSymbolicLink(resolvedCandidate, below: resolvedRoot)
        else { throw .pathEscapesRoot }
        return resolvedCandidate
    }

    /// Foundation leaves unresolved tails alone. Resolve the deepest existing ancestor so
    /// an inside symlink to outside cannot conceal an as-yet nonexistent child.
    private static func resolveThroughExistingAncestors(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var remainder: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            remainder.append(existing.lastPathComponent)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in remainder.reversed() { resolved.append(path: component) }
        return resolved
    }

    /// Inspect links themselves with lstat. A dangling link can redirect a subsequent create
    /// even though fileExists returns false; a symlink loop is likewise not a usable ancestor.
    private static func containsDanglingSymbolicLink(_ url: URL, below root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents
        else { return false }
        var current = root.standardizedFileURL
        for component in components.dropFirst(rootComponents.count) {
            current.append(path: component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return false }
            if (info.st_mode & S_IFMT) == S_IFLNK, stat(current.path, &info) != 0 { return true }
        }
        return false
    }
}
