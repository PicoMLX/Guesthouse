import Foundation

/// Pure checks the service applies to every message before acting on it
/// (MVP-PLAN.md §3: "validate message sizes and paths, reject symlink escapes").
public enum RequestValidator {
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
              handoff.displayName.count <= maximumDisplayNameLength,
              !handoff.displayName.contains("/"),
              !handoff.displayName.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw .invalidDisplayName
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
        let resolvedRoot = resolveThroughExistingAncestors(root)
        let resolvedCandidate = resolveThroughExistingAncestors(candidate)
        let rootComponents = resolvedRoot.pathComponents
        let candidateComponents = resolvedCandidate.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
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
