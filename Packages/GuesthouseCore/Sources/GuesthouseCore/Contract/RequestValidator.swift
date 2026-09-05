import Darwin
import Foundation

/// Pure checks the service applies to every message before acting on it
/// (MVP-PLAN.md §3: "validate message sizes and paths, reject symlink escapes").
public enum RequestValidator: Sendable {
    /// Larger than any legitimate message (a security-scoped bookmark is a few kilobytes).
    public static let maximumEncodedSize = 64 * 1024
    public static let maximumBookmarkSize = 16 * 1024
    public static let maximumDisplayNameLength = 255
    public static let maximumIPWait: Duration = .seconds(300)
    public static let maximumGracefulStopDeadline: Duration = .seconds(600)

    /// Validates the raw bytes before decoding, so an oversized message never reaches the decoder.
    public static func validateEncodedSize(_ data: Data) throws(RequestValidationError) {
        guard data.count <= maximumEncodedSize else {
            throw .oversized(bytes: data.count, limit: maximumEncodedSize)
        }
    }

    /// Validates a decoded envelope: protocol version, option bounds, handoff sizes.
    public static func validate(_ envelope: RuntimeRequestEnvelope) throws(RequestValidationError) {
        guard envelope.protocolVersion == .current else {
            throw .protocolMismatch(client: envelope.protocolVersion, service: .current)
        }
        switch envelope.request {
        case .runtimeVersion, .environmentStatus, .cancelOperation:
            break
        case .startEnvironment(_, let options):
            guard options.ipWait >= .zero, options.ipWait <= maximumIPWait else {
                throw .optionOutOfRange("ipWait")
            }
        case .stopEnvironment(_, .graceful(let deadline)):
            guard deadline > .zero, deadline <= maximumGracefulStopDeadline else {
                throw .optionOutOfRange("deadline")
            }
        case .stopEnvironment(_, .force):
            break
        case .importXcode(_, let handoff):
            try validate(handoff)
        }
    }

    public static func validate(_ handoff: FileHandoff) throws(RequestValidationError) {
        if case .securityScopedBookmark(let data) = handoff.kind {
            guard !data.isEmpty, data.count <= maximumBookmarkSize else {
                throw .oversized(bytes: data.count, limit: maximumBookmarkSize)
            }
        }
        guard !handoff.displayName.isEmpty,
              handoff.displayName.unicodeScalars.count <= maximumDisplayNameLength,
              handoff.displayName.utf8.count <= maximumDisplayNameLength * 4,
              !handoff.displayName.contains("/"),
              !handoff.displayName.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator: true
                  default: false
                  }
              }),
              // The name is kept for progress and errors, where it is shown as it arrived, and
              // nothing downstream redacts a display value again. Refusing rather than
              // rewriting keeps the user's own file name honest: showing something other than
              // what they picked would be worse than declining the selection.
              !carriesCredential(handoff.displayName)
        else {
            throw .invalidDisplayName
        }
    }

    /// Whether the redactor recognizes a credential in a file name, examined whole and by
    /// dot-separated part. A name is a single Unicode word across its dots, so a token that
    /// ends where an extension begins (`ghp_….app`) reaches no word boundary the patterns can
    /// anchor on; the whole name is examined as well, so a credential that needs its dots,
    /// such as a JWT, is still recognized.
    static func carriesCredential(_ name: String) -> Bool {
        ([name] + name.split(separator: ".").map(String.init)).contains {
            GuesthouseError.sanitizeReporting($0, limit: maximumDisplayNameLength).redacted
        }
    }

    /// App-managed VM names are exactly `guesthouse-<lowercase uuid>`; anything else could
    /// address a VM Guesthouse does not own.
    public static func validateVMName(_ name: String) throws(RequestValidationError) {
        guard name.hasPrefix("guesthouse-"),
              let uuid = UUID(uuidString: String(name.dropFirst("guesthouse-".count))),
              name == EnvironmentID(uuid: uuid).tartVMName
        else {
            throw .invalidVMName
        }
    }

    /// Resolves `candidate` and proves it lies inside `root` after following every symlink.
    ///
    /// Both paths are resolved with `realpath` semantics, so a symlink inside the root that
    /// points outside is rejected, as is `..` traversal and a sibling directory whose name
    /// merely starts with the root's name. Returns the resolved location.
    public static func validateContainment(of candidate: URL, within root: URL) throws(RequestValidationError) -> URL {
        guard candidate.isFileURL, root.isFileURL else { throw .invalidPath }
        guard !candidate.pathComponents.contains("..") else { throw .pathEscapesRoot }
        // The root and every one of its ancestors must resolve: a dangling link anywhere in
        // the chain would send a later create through it, outside the allowed location.
        guard !containsDanglingSymbolicLink(root, below: URL(fileURLWithPath: "/")) else { throw .pathEscapesRoot }
        let resolvedRoot = resolveThroughExistingAncestors(root)
        let resolvedCandidate = resolveThroughExistingAncestors(candidate)
        let rootComponents = resolvedRoot.pathComponents
        let candidateComponents = resolvedCandidate.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw .pathEscapesRoot
        }
        // A link that resolves inside the root was followed above and is fine; a dangling
        // link is not resolvable, so it must be refused: the first write through it would
        // create the target wherever the link points. Both the path as given and the path
        // with its existing ancestors resolved are walked, so a root reached through an
        // alias is checked where the components actually live.
        guard !containsDanglingSymbolicLink(candidate, below: root),
              !containsDanglingSymbolicLink(resolvedCandidate, below: resolvedRoot)
        else {
            throw .pathEscapesRoot
        }
        return resolvedCandidate
    }
}

extension RequestValidator {
    /// `resolvingSymlinksInPath()` leaves a path untouched when a component does not exist,
    /// which would let `<symlink-to-outside>/new-file` pass. This resolves the deepest existing
    /// ancestor with real symlink resolution and re-attaches the remaining components.
    static func resolveThroughExistingAncestors(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var remainder: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            remainder.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in remainder {
            resolved.append(path: component)
        }
        return resolved
    }

    /// Whether any component of `url` below `root` is a symbolic link whose target does not
    /// exist. Each component is examined with `lstat`, so the link itself is seen rather than
    /// what it points at; a dangling link (`root/link -> /outside/new-file`) does not exist
    /// as a file, but the first write through it would create the target.
    static func containsDanglingSymbolicLink(_ url: URL, below root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        // Only a path that lexically continues the root can be walked from it; anything else
        // is already refused by the containment check above.
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

public enum RequestValidationError: Error, Hashable, Sendable {
    case oversized(bytes: Int, limit: Int)
    case protocolMismatch(client: RuntimeProtocolVersion, service: RuntimeProtocolVersion)
    case optionOutOfRange(String)
    case invalidDisplayName
    case invalidVMName
    case invalidPath
    case pathEscapesRoot

    /// The user-facing error the service reports for this rejection.
    public var guesthouseError: GuesthouseError {
        switch self {
        case .oversized: .invalidRequest(.oversized)
        case .protocolMismatch(let client, let service): .protocolMismatch(client: client.rawValue, service: service.rawValue)
        case .optionOutOfRange, .invalidDisplayName, .invalidPath: .invalidRequest(.malformed)
        case .invalidVMName: .invalidRequest(.invalidVMName)
        case .pathEscapesRoot: .invalidRequest(.pathEscapesAllowedRoot)
        }
    }
}
