import Foundation

/// A Git remote, normalized so that the same repository is recognized whatever URL form the
/// user or `git remote -v` supplied (MVP-PLAN.md §6: "canonical remotes").
///
/// Accepted forms: `https://host/owner/name(.git)`, `ssh://git@host/owner/name(.git)`, and
/// `git@host:owner/name(.git)`. Owners follow GitHub's account-name rules; repository names
/// take GitHub's wider alphabet. Both keep their case; comparisons ignore it because GitHub does.
public struct RemoteURL: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let owner: String
    public let name: String

    public static let supportedHosts: Set<String> = ["github.com"]

    public init?(_ string: String) {
        // Surrounding whitespace is refused rather than trimmed: `git remote` reports a
        // configured origin verbatim, and an origin with a trailing space is a URL Git itself
        // rejects, so trimming would let it pass as the expected canonical remote.
        guard !string.isEmpty, !string.contains(where: \.isWhitespace) else { return nil }

        // Percent escapes and explicit ports are refused rather than normalized: SwiftPM keeps
        // the URL spelling when it derives identities, and a port names a different endpoint.
        guard !string.contains("%") else { return nil }
        var host: String
        var path: String
        // Only a URL form may carry the trailing slash a browser's address bar adds.
        let isURLForm: Bool
        // SCP-style remotes must name GitHub's `git` account for the same reason SSH URLs do.
        if let scpRange = string.firstRange(of: #/^git@[A-Za-z0-9.-]+:/#) {
            let prefix = String(string[scpRange])
            host = String(prefix.split(separator: "@")[1].dropLast())
            path = String(string[scpRange.upperBound...])
            // An SCP path is relative to the account's home directory; a leading separator
            // makes it absolute on the server, which is a different repository.
            guard !path.hasPrefix("/") else { return nil }
            isURLForm = false
        } else if let components = URLComponents(string: string), let scheme = components.scheme?.lowercased(), let urlHost = components.host {
            // Only the documented transports, and nothing the canonical form would drop: a
            // port, query, fragment, or user other than SSH's `git` names something else.
            // SSH remotes must name GitHub's `git` account; without it SSH would use the guest
            // account and every clone or push would fail.
            guard ["https", "ssh"].contains(scheme), components.port == nil, components.query == nil, components.fragment == nil,
                  components.password == nil, scheme == "https" ? components.user == nil : components.user == "git"
            else { return nil }
            host = urlHost
            path = components.path
            guard path.hasPrefix("/") else { return nil }
            path.removeFirst()
            isURLForm = true
        } else {
            return nil
        }

        host = host.lowercased()
        // An empty component is not the same as no component: `/Org/Repo` and `Org//Repo` ask
        // the server for paths it resolves differently from `Org/Repo`, so canonicalizing them
        // to the same remote would let origin inspection accept an unexpected repository.
        // Only the one trailing slash a URL form may carry is dropped.
        if isURLForm, path.hasSuffix("/") { path.removeLast() }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[1].lowercased().hasSuffix(".git") { parts[1] = String(parts[1].dropLast(4)) }
        // A repository whose own name ends in `.git` has no round-trippable canonical form:
        // the canonical URL would lose the suffix on the next parse, silently naming a
        // different repository. Such a remote is refused rather than normalized.
        guard !parts[1].lowercased().hasSuffix(".git") else { return nil }
        guard Self.isValidOwner(parts[0]), Self.isValidRepositoryName(parts[1]) else { return nil }
        self.host = host
        owner = parts[0]
        name = parts[1]
    }

    /// `https://github.com/Owner/Name`, without `.git`.
    public var canonical: String { "https://\(host)/\(owner)/\(name)" }
    public var description: String { canonical }

    public var isSupportedHost: Bool { Self.supportedHosts.contains(host) }

    /// Case-insensitive identity, for uniqueness checks.
    public var identity: String { "\(host)/\(owner.lowercased())/\(name.lowercased())" }

    public static func == (lhs: RemoteURL, rhs: RemoteURL) -> Bool { lhs.identity == rhs.identity }
    public func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    /// An account name cannot hold `.` or `_` and cannot exceed 39 characters, so an owner that
    /// no GitHub account could carry is refused here rather than at a clone that cannot resolve.
    private static func isValidOwner(_ owner: String) -> Bool {
        (1...39).contains(owner.count) && !owner.hasPrefix("-") && !owner.hasSuffix("-")
            && owner.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A repository name takes GitHub's wider alphabet, which also allows `_` and `.`.
    private static func isValidRepositoryName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 100 && name != "." && name != ".." && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
}

extension RemoteURL: Codable {
    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let remote = RemoteURL(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a repository URL: \(string)"))
        }
        self = remote
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonical)
    }
}
