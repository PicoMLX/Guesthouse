import Foundation

/// A SwiftPM package identity, derived the way SwiftPM derives it for a Git URL dependency:
/// the last path component of the location, without a `.git` suffix, lowercased
/// (`PackageIdentity.swift` in swift-package-manager). It is not the `Package(name:)` in the
/// manifest, which may differ (MVP-PLAN.md §6).
public struct PackageIdentity: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(location: String) {
        var text = location.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let last = text.split(separator: "/").last.map(String.init) ?? text.split(separator: ":").last.map(String.init), !last.isEmpty else {
            return nil
        }
        var name = last
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        rawValue = name.lowercased()
    }

    public init(remote: RemoteURL) {
        rawValue = remote.name.lowercased()
    }

    public var description: String { rawValue }
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
            guard let identityRaw = raw["identity"] as? String, let identity = PackageIdentity(location: identityRaw) else { throw .malformed("identity") }
            guard let kindRaw = raw["kind"] as? String else { throw .malformed("kind") }
            guard let kind = Pin.Kind(rawValue: kindRaw) else { throw .unknownKind(kindRaw) }
            guard let location = raw["location"] as? String else { throw .malformed("location") }
            let state = raw["state"] as? [String: Any] ?? [:]
            pins.append(Pin(identity: identity, kind: kind, location: location, revision: state["revision"] as? String, version: state["version"] as? String, branch: state["branch"] as? String))
        }
        return ResolvedPackagesFile(version: version, pins: pins)
    }
}

public enum ResolvedPackagesError: Error, Hashable, Sendable {
    case notJSON
    case missingVersion
    case unsupportedVersion(Int)
    case unknownKind(String)
    case malformed(String)
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
    }

    public static func match(selected: [WorkspaceRepository], resolved: ResolvedPackagesFile) -> [MatchResult] {
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
            results.append(.matched(identity: identity, location: pin.location))
        }
        return results
    }
}
