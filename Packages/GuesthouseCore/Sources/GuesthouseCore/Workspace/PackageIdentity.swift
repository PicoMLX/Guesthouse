import Foundation

/// A SwiftPM package identity, derived the way SwiftPM derives it for a Git URL dependency:
/// the last path component of the location, without a `.git` suffix, lowercased
/// (`PackageIdentity.swift` in swift-package-manager). It is not the `Package(name:)` in the
/// manifest, which may differ (MVP-PLAN.md §6).
public struct PackageIdentity: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(location: String) {
        // Follow SwiftPM's Unix default-name derivation: remove at most one trailing
        // slash. Repeated trailing separators produce no usable identity, not a normalized
        // location. Input is private metadata, never a command-output transcript.
        guard !WorkspaceTextRules.containsDisplayControls(location) else { return nil }
        var text = location
        if text.hasSuffix("/") { text.removeLast() }
        // The path separator is the only separator SwiftPM uses. An SCP-form remote has none,
        // so `git@host:Name.git` is the package `git@host:name`, not `name`; splitting on the
        // colon here would name a package that no `Package.resolved` entry carries.
        var name: String
        if let slash = text.lastIndex(of: "/") {
            name = String(text[text.index(after: slash)...])
        } else {
            name = text
        }
        // SwiftPM strips only a lowercase `.git`, independently of remote normalization, so `Mixed-Repo.GIT`
        // stays the package `mixed-repo.git` that `Package.resolved` will name.
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        rawValue = name.lowercased()
    }

    public init(remote: RemoteURL) {
        rawValue = remote.name.lowercased()
    }

    /// The identity SwiftPM derives from a local checkout directory: the basename with a
    /// terminal lowercase `.git` removed, lowercased. This is the rule that decides whether a
    /// local package can replace a pinned dependency.
    public init(checkoutName: DirectoryName) {
        var name = checkoutName.rawValue
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        rawValue = name.lowercased()
    }

    /// An identity exactly as `Package.resolved` spells it. SwiftPM has already canonicalized
    /// it, so no location rules (such as dropping `.git`) are applied again.
    ///
    /// SwiftPM derives an identity from a checkout basename, which may legitimately hold
    /// non-ASCII letters or spaces (`cafékit`, `space kit`), and re-resolving writes the same
    /// file back; refusing those would reject the whole lockfile with advice that cannot
    /// work. Only spellings that could not name a package at all are refused.
    ///
    /// A boundary space is part of the identity for the same reason: a checkout named ` Foo `
    /// is the package `" foo "`, and folding it onto `foo` would merge two distinct pins into
    /// one identity, report a collision, and block an override no re-resolve could unblock.
    public init?(resolvedIdentity: String) {
        guard !resolvedIdentity.isEmpty, !resolvedIdentity.contains("/"), resolvedIdentity != ".", resolvedIdentity != "..",
              !WorkspaceTextRules.containsDisplayControls(resolvedIdentity)
        else { return nil }
        rawValue = resolvedIdentity.lowercased()
    }

    public var description: String { rawValue }
}

extension PackageIdentity: Codable {
    /// Decoding is another way into the type, so it applies the same lowercasing and the same
    /// refusals its initializers do; a hand-edited `SharedUI` or an empty name would otherwise
    /// hash and compare differently from the identity derived for the same package.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .rawValue)
        guard let identity = PackageIdentity(resolvedIdentity: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid package identity."))
        }
        self = identity
    }
}

