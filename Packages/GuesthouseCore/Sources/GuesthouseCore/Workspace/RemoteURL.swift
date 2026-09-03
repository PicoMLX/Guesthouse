import Foundation

/// A Git remote, normalized so that the same repository is recognized whatever URL form the
/// user or `git remote -v` supplied (MVP-PLAN.md §6: "canonical remotes").
///
/// Accepted forms: `https://host/owner/name(.git)`, `ssh://git@host/owner/name(.git)`, and
/// `git@host:owner/name(.git)`. Owner and name are ASCII letters, digits, `-`, `_`, and `.`
/// (GitHub's own alphabet) and keep their case; comparisons ignore it because GitHub does.
public struct RemoteURL: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let owner: String
    public let name: String

    public static let supportedHosts: Set<String> = ["github.com"]

    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }

        // Percent escapes and explicit ports are refused rather than normalized: SwiftPM keeps
        // the URL spelling when it derives identities, and a port names a different endpoint.
        guard !text.contains("%") else { return nil }
        var host: String
        var path: String
        // SCP-style remotes must name GitHub's `git` account for the same reason SSH URLs do.
        if let scpRange = text.firstRange(of: #/^git@[A-Za-z0-9.-]+:/#) {
            let prefix = String(text[scpRange])
            host = String(prefix.split(separator: "@")[1].dropLast())
            path = String(text[scpRange.upperBound...])
        } else if let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), let urlHost = components.host {
            // Only the documented transports, and nothing the canonical form would drop: a
            // port, query, fragment, or user other than SSH's `git` names something else.
            // SSH remotes must name GitHub's `git` account; without it SSH would use the guest
            // account and every clone or push would fail.
            guard ["https", "ssh"].contains(scheme), components.port == nil, components.query == nil, components.fragment == nil,
                  components.password == nil, scheme == "https" ? components.user == nil : components.user == "git"
            else { return nil }
            host = urlHost
            path = components.path
        } else {
            return nil
        }

        host = host.lowercased()
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        // SwiftPM strips only a lowercase `.git` when it derives an identity from a location,
        // so this parser does the same: `Repo.GIT` keeps its suffix, and its identity stays
        // `repo.git`, which is what `Package.resolved` will spell.
        if parts[1].hasSuffix(".git") { parts[1] = String(parts[1].dropLast(4)) }
        // A repository whose own name then still ends in a lowercase `.git` has no
        // round-trippable canonical form: the canonical URL would lose the suffix on the next
        // parse, silently naming a different repository. Such a remote is refused.
        guard !parts[1].hasSuffix(".git") else { return nil }
        guard Self.isValidComponent(parts[0]), Self.isValidComponent(parts[1]) else { return nil }
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

    private static func isValidComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
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
