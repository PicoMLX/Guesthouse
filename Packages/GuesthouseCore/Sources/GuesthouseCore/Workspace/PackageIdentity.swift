import Foundation

/// A SwiftPM package identity, derived the way SwiftPM derives it for a Git URL dependency:
/// the last path component of the location, without a `.git` suffix, lowercased
/// (`PackageIdentity.swift` in swift-package-manager). It is not the `Package(name:)` in the
/// manifest, which may differ (MVP-PLAN.md §6).
public struct PackageIdentity: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(location: String) {
        var text = location.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        // An SCP-form remote (`git@host:Name.git`) has no slash at all, so the colon that
        // separates the host from the path is the only separator there is; splitting on `/`
        // alone would keep `git@host:` inside the identity.
        var name: String
        if let slash = text.lastIndex(of: "/") {
            name = String(text[text.index(after: slash)...])
        } else if let colon = text.lastIndex(of: ":") {
            name = String(text[text.index(after: colon)...])
        } else {
            name = text
        }
        // SwiftPM strips only a lowercase `.git`, the way `RemoteURL` does, so `Mixed-Repo.GIT`
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
    public init?(resolvedIdentity: String) {
        let text = resolvedIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("/"), text != ".", text != "..",
              !WorkspaceManifest.containsControlCharacters(text)
        else { return nil }
        rawValue = text.lowercased()
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
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a package identity: \(raw)"))
        }
        self = identity
    }
}

/// The parts of `Package.resolved` (versions 2 and 3) that matter for matching local overrides.
public struct ResolvedPackagesFile: Hashable, Sendable {
    public struct Pin: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            case remoteSourceControl
            case localSourceControl
            case registry
            case fileSystem
        }

        public let identity: PackageIdentity
        public let kind: Kind
        public let location: String
        public let revision: String?
        public let version: String?
        public let branch: String?
    }

    public let version: Int
    public let pins: [Pin]

    public init(version: Int, pins: [Pin]) {
        self.version = version
        self.pins = pins
    }

    public static func decode(_ data: Data) throws(ResolvedPackagesError) -> ResolvedPackagesFile {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .notJSON }
        guard let version = object["version"] as? Int else { throw .missingVersion }
        guard version == 2 || version == 3 else { throw .unsupportedVersion(version) }
        guard let rawPins = object["pins"] as? [[String: Any]] else { throw .malformed("pins") }
        var pins: [Pin] = []
        for raw in rawPins {
            guard let identityRaw = raw["identity"] as? String, let identity = PackageIdentity(resolvedIdentity: identityRaw) else { throw .malformed("identity") }
            guard let kindRaw = raw["kind"] as? String else { throw .malformed("kind") }
            guard let kind = Pin.Kind(rawValue: kindRaw) else { throw .unknownKind(kindRaw) }
            guard let location = raw["location"] as? String else { throw .malformed("location") }
            let state = raw["state"] as? [String: Any] ?? [:]
            pins.append(Pin(identity: identity, kind: kind, location: location, revision: state["revision"] as? String, version: state["version"] as? String, branch: state["branch"] as? String))
        }
        return ResolvedPackagesFile(version: version, pins: pins)
    }
}

public enum ResolvedPackagesError: Error, Hashable, Sendable, LocalizedError {
    case notJSON
    case missingVersion
    case unsupportedVersion(Int)
    case unknownKind(String)
    case malformed(String)

    public var userMessage: String {
        switch self {
        case .notJSON: "The app's Package.resolved is not valid JSON. Resolve packages in Xcode and commit the file, then try again."
        case .missingVersion: "The app's Package.resolved has no version field. Resolve packages in Xcode and commit the file, then try again."
        case .unsupportedVersion(let version): "The app's Package.resolved uses format \(version), which this version of Guesthouse does not read. Update Guesthouse, or resolve packages with the Xcode version Guesthouse supports."
        case .unknownKind(let kind): "The app's Package.resolved pins a dependency of kind \(GuesthouseError.sanitize(kind)), which Guesthouse does not understand. Update Guesthouse."
        case .malformed(let field): "The app's Package.resolved has an unreadable \(GuesthouseError.sanitize(field)) entry. Resolve packages in Xcode and commit the file, then try again."
        }
    }

    /// In preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unsupportedVersion, .unknownKind: [.reinstallApp, .retry, .cancel]
        default: [.retry, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}

/// Decides, for each package repository the user selected, whether it can safely override one
/// of the app's resolved dependencies (MVP-PLAN.md §6: match identity and canonical origin,
/// never only the display name; reject ambiguous identities).
public enum LocalOverrideMatcher {
    public enum MatchResult: Hashable, Sendable {
        /// The selected repository is exactly this remote-source-control dependency.
        case matched(identity: PackageIdentity, location: String)
        /// The resolved file pins more than one location to this identity, or the selection
        /// shares an identity with another selected repository. Refuse rather than guess.
        case collision(identity: PackageIdentity, locations: [String])
        /// The app does not depend on this package, directly or transitively.
        case notADependency(identity: PackageIdentity)
        /// The dependency exists but is not a Git URL dependency (registry or local path).
        case unsupportedKind(identity: PackageIdentity, kind: ResolvedPackagesFile.Pin.Kind)
        /// Same identity, different repository. Overriding would silently substitute code.
        case remoteMismatch(identity: PackageIdentity, expected: String, selected: String)
        /// The checkout directory's basename would give SwiftPM a different local identity,
        /// so the override would never apply.
        case checkoutNameMismatch(identity: PackageIdentity, checkout: String)
        /// The checkout's actual `origin` is not the selected repository.
        case originMismatch(identity: PackageIdentity, expected: String, observed: String)
        /// No `origin` was read for the checkout, so the clone was never inspected. An
        /// override is never approved on an unread checkout.
        case originUnknown(identity: PackageIdentity, checkout: String)
    }

    /// - Parameters:
    ///   - selected: the repositories the workspace names.
    ///   - resolved: the app's `Package.resolved`.
    ///   - observedOrigins: the `origin` remote of each existing checkout, keyed by checkout
    ///     name, as read from the clone by the caller. Every selected package needs an entry:
    ///     an origin that differs is refused, and one that was never read is refused too,
    ///     since an unread checkout is not evidence of anything.
    public static func match(selected: [WorkspaceRepository], resolved: ResolvedPackagesFile, observedOrigins: [DirectoryName: RemoteURL]) -> [MatchResult] {
        let packages = selected.filter { $0.role == .package }
        var results: [MatchResult] = []
        let selectedIdentities = Dictionary(grouping: packages, by: { PackageIdentity(remote: $0.remote) })
        let pinsByIdentity = Dictionary(grouping: resolved.pins, by: \.identity)

        for repository in packages {
            let identity = PackageIdentity(remote: repository.remote)
            if let siblings = selectedIdentities[identity], siblings.count > 1 {
                results.append(.collision(identity: identity, locations: siblings.map(\.remote.canonical).sorted()))
                continue
            }
            guard let pins = pinsByIdentity[identity], !pins.isEmpty else {
                results.append(.notADependency(identity: identity))
                continue
            }
            if pins.count > 1 {
                results.append(.collision(identity: identity, locations: pins.map(\.location).sorted()))
                continue
            }
            let pin = pins[0]
            guard pin.kind == .remoteSourceControl else {
                results.append(.unsupportedKind(identity: identity, kind: pin.kind))
                continue
            }
            guard let pinned = RemoteURL(pin.location), pinned == repository.remote else {
                results.append(.remoteMismatch(identity: identity, expected: pin.location, selected: repository.remote.canonical))
                continue
            }
            // SwiftPM derives the local package's identity from the directory name, so the
            // checkout's own identity must equal the dependency's. A name the workspace had
            // to derive differently is refused rather than approved under another identity.
            guard PackageIdentity(checkoutName: repository.checkoutName) == identity else {
                results.append(.checkoutNameMismatch(identity: identity, checkout: repository.checkoutName.rawValue))
                continue
            }
            guard let origin = observedOrigins[repository.checkoutName] else {
                results.append(.originUnknown(identity: identity, checkout: repository.checkoutName.rawValue))
                continue
            }
            guard origin == repository.remote else {
                results.append(.originMismatch(identity: identity, expected: repository.remote.canonical, observed: origin.canonical))
                continue
            }
            results.append(.matched(identity: identity, location: pin.location))
        }
        return results
    }
}
