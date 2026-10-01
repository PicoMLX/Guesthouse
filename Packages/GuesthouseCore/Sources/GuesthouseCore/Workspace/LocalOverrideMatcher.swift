import Foundation

/// Decides, for each package repository the user selected, whether it can safely override one
/// of the app's resolved dependencies based on supplied observations (MVP-PLAN.md §6: canonical origin,
/// never only the display name; reject ambiguous identities).
/// Read-only planning only: callers must bind observations to the current guest/workspace
/// before any action. These private metadata results are never diagnostic event payloads.
public enum LocalOverrideMatcher: Sendable {
    public enum MatchResult: Hashable, Sendable {
        case unsupportedHost(identity: PackageIdentity)
        case checkoutCollision(identity: PackageIdentity)
        /// The selected repository is exactly this remote-source-control dependency.
        case matched(identity: PackageIdentity, location: String)
        /// The resolved file pins more than one location to this identity, or the selection
        /// shares an identity with another selected repository. Refuse rather than guess.
        case collision(identity: PackageIdentity, locations: [String])
        /// The app does not depend on this package, directly or transitively.
        case notADependency(identity: PackageIdentity)
        /// The app pins this repository, but under an identity a local checkout cannot carry,
        /// so the override would never take effect. A dependency mirror does this: SwiftPM
        /// writes the mirror's identity and maps the location back to the original URL. So
        /// does a percent-encoded location: GitHub resolves `foo%2Dbar` to the same repository
        /// as `foo-bar`, while SwiftPM keeps the spelling and pins the identity `foo%2dbar`.
        case identityMismatch(identity: PackageIdentity, pinned: PackageIdentity, location: String)
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

        let checkouts = Dictionary(grouping: selected, by: { $0.checkoutName.identity })
        for repository in packages {
            let identity = PackageIdentity(remote: repository.remote)
            if let siblings = selectedIdentities[identity], siblings.count > 1 {
                results.append(.collision(identity: identity, locations: siblings.map(\.remote.canonical).sorted()))
                continue
            }
            guard repository.remote.isSupportedHost else {
                results.append(.unsupportedHost(identity: identity)); continue
            }
            guard checkouts[repository.checkoutName.identity]?.count == 1 else {
                results.append(.checkoutCollision(identity: identity)); continue
            }
            guard let pins = pinsByIdentity[identity], !pins.isEmpty else {
                // A mirrored dependency is pinned at its original location under the mirror's
                // identity, so the app does depend on the selected repository even though no
                // pin carries its identity. Reporting that as an absent dependency would send
                // the user to add a dependency the app already has.
                if let elsewhere = resolved.pins.first(where: { Self.locates(repository.remote, $0.location) }) {
                    results.append(.identityMismatch(identity: identity, pinned: elsewhere.identity, location: elsewhere.location))
                } else {
                    results.append(.notADependency(identity: identity))
                }
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

    /// Whether a pin's location names this repository, including through percent escapes.
    ///
    /// `RemoteURL` refuses an encoded spelling because SwiftPM keeps it when deriving the
    /// identity, which is exactly why such a pin has to be found here: the repository is a
    /// dependency, so reporting it as absent would tell the user to add one the app already
    /// has. The decoded form is only ever used to recognize the pin, never to approve it.
    private static func locates(_ remote: RemoteURL, _ location: String) -> Bool {
        if RemoteURL(location) == remote { return true }
        guard location.contains("%"), let decoded = location.removingPercentEncoding else { return false }
        return RemoteURL(decoded) == remote
    }
}

public extension LocalOverrideMatcher.MatchResult {
    var userMessage: String {
        switch self {
        case .matched: "The package matches the recorded dependency and supplied checkout origin."
        case .collision: "More than one package uses the same dependency identity."
        case .notADependency: "The selected package is not in the app's resolved dependencies."
        case .identityMismatch: "The recorded dependency uses a different package identity."
        case .unsupportedKind: "This dependency kind does not support a Git checkout override."
        case .unsupportedHost: "Only github.com package repositories are supported."
        case .checkoutCollision: "Two selected repositories use the same checkout folder."
        case .remoteMismatch: "The selected repository differs from the recorded dependency."
        case .checkoutNameMismatch: "The checkout folder gives the package a different identity."
        case .originMismatch: "The observed checkout origin differs from the selected repository."
        case .originUnknown: "The checkout origin has not been inspected."
        }
    }
    var recoveryMessage: String {
        switch self {
        case .matched: "Confirm the observations still describe the current workspace before applying an approved package workflow."
        case .originUnknown, .originMismatch: "Inspect the existing clone and preserve its work before changing an origin or retrying a clone."
        default: "Review package selections, checkout folders and the app's canonical lockfile. Resolve the mismatch before applying local overrides."
        }
    }
    var recoveryActions: [RecoveryAction] {
        if case .matched = self { return [] }
        return [.inspectState, .openSettings, .cancel]
    }
}
