import Foundation

/// The parts of `Package.resolved` (versions 2 and 3) that matter for matching local overrides.
public struct ResolvedPackagesFile: Hashable, Sendable {
    public struct Pin: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            case remoteSourceControl
            case localSourceControl
            case registry
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

    /// A lockfile pins one entry of a few hundred bytes per dependency, so this is room for
    /// thousands of them. The file is committed in a repository the workspace only selected,
    /// so its size is bounded before `JSONSerialization` materializes the whole document and
    /// the pin arrays are built from it.
    public static let maximumEncodedSize = 1024 * 1024

    private struct VersionEnvelope: Decodable { let version: Int }

    public static func decode(_ data: Data) throws(ResolvedPackagesError) -> ResolvedPackagesFile {
        guard data.count <= Self.maximumEncodedSize else { throw .tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .notJSON }
        guard let version = try? JSONDecoder().decode(VersionEnvelope.self, from: data).version else { throw .missingVersion }
        guard version == 2 || version == 3 else { throw .unsupportedVersion }
        if version == 3 { _ = try string(object["originHash"], field: .originHash) }
        guard let rawPins = object["pins"] as? [[String: Any]] else { throw .malformed(.pins) }
        var pins: [Pin] = []
        var identities: Set<PackageIdentity> = []
        for raw in rawPins {
            guard let identityRaw = raw["identity"] as? String, let identity = PackageIdentity(resolvedIdentity: identityRaw) else { throw .malformed(.identity) }
            guard identities.insert(identity).inserted else { throw .malformed(.duplicateIdentity) }
            guard let kindRaw = raw["kind"] as? String else { throw .malformed(.kind) }
            guard let kind = Pin.Kind(rawValue: kindRaw) else { throw .unknownKind }
            guard let location = raw["location"] as? String else { throw .malformed(.location) }
            // SwiftPM's Unix AbsolutePath validation is syntactic: the path must
            // start with `/`. Do not inspect the host or change the stored spelling.
            if kind == .localSourceControl, !location.hasPrefix("/") { throw .malformed(.location) }
            let state = try decodeState(raw["state"], kind: kind)
            pins.append(Pin(identity: identity, kind: kind, location: location, revision: state.revision, version: state.version, branch: state.branch))
        }
        return ResolvedPackagesFile(version: version, pins: pins)
    }

    /// SwiftPM records the commit it checked out for every source-control pin, so a pin whose
    /// `state` is absent, is not an object, or names no revision is a corrupted lockfile.
    /// Reading it as a pin with no metadata would let an override be approved against a pin
    /// that identifies no code, and the failure would surface later, at the build.
    private static func decodeState(_ raw: Any?, kind: Pin.Kind) throws(ResolvedPackagesError) -> (revision: String?, version: String?, branch: String?) {
        let isSourceControl = kind == .remoteSourceControl || kind == .localSourceControl
        guard let raw, !(raw is NSNull) else { throw .malformed(.state) }
        guard let fields = raw as? [String: Any] else { throw .malformed(.state) }
        let revision = try string(fields["revision"], field: .revision)
        let version = try string(fields["version"], field: .semanticVersion)
        let branch = try string(fields["branch"], field: .branch)
        // SwiftPM writes the full Git object ID it resolved, so a revision that is not one
        // names no commit and is as corrupt as an absent one, whether it is blank or a branch
        // name: an override approved against it would fail at resolution or at the build
        // instead of here, where the lockfile can still be re-resolved.
        if isSourceControl, CommitSHA(revision ?? "") == nil { throw .malformed(.revision) }
        // SwiftPM parses a pinned version with the semantic-version grammar and refuses the
        // whole file when it does not parse, so text such as `not-semver` names a lockfile the
        // wrapper cannot be seeded from. It is caught here, while the repair is still to
        // resolve packages in Xcode and commit the result.
        if let version, !isSemanticVersion(version) { throw .malformed(.semanticVersion) }
        if kind == .registry, version == nil { throw .malformed(.semanticVersion) }
        return (revision, version, branch)
    }

    /// SwiftPM's TSCUtility.Version parser accepts leading zeros and empty
    /// prerelease/build identifiers, but numeric components must fit in Int.
    /// Keep the canonical lockfile's spelling rather than normalizing it.
    static func isSemanticVersion(_ text: String) -> Bool {
        var numbers = Substring(text)
        // Build metadata is split off first: it may contain hyphens, which would otherwise
        // read as the start of a prerelease.
        if let plus = numbers.firstIndex(of: "+") {
            let metadata = numbers[numbers.index(after: plus)...]
            numbers = numbers[..<plus]
            guard isVersionIdentifiers(metadata) else { return false }
        }
        if let hyphen = numbers.firstIndex(of: "-") {
            let prerelease = numbers[numbers.index(after: hyphen)...]
            numbers = numbers[..<hyphen]
            guard isVersionIdentifiers(prerelease) else { return false }
        }
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            Int(part) != nil && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    private static func isVersionIdentifiers(_ text: Substring) -> Bool {
        let identifiers = text.split(separator: ".", omittingEmptySubsequences: false)
        return identifiers.allSatisfy { identifier in
            identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// A present-but-unreadable field is refused rather than dropped, so a lockfile that spells
    /// a version or branch as something other than text is not silently read as having none.
    private static func string(_ raw: Any?, field: ResolvedPackagesError.Field) throws(ResolvedPackagesError) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let text = raw as? String else { throw .malformed(field) }
        return text
    }
}

/// Only closed field names and fixed recovery guidance cross the error boundary.
public enum ResolvedPackagesError: Error, Hashable, Sendable, LocalizedError {
    public enum Field: String, Hashable, Sendable {
        case pins, identity, duplicateIdentity, kind, location, state, revision, semanticVersion, branch, originHash
    }
    case notJSON, missingVersion, unsupportedVersion, unknownKind, malformed(Field), tooLarge

    public var userMessage: String {
        switch self {
        case .notJSON: "The app's Package.resolved is not a JSON object."
        case .missingVersion: "The app's Package.resolved has no valid format version."
        case .unsupportedVersion: "This Guesthouse build reads Package.resolved formats 2 and 3 only."
        case .unknownKind: "The app's Package.resolved contains an unsupported dependency kind."
        case .malformed: "The app's Package.resolved contains invalid or duplicate dependency metadata."
        case .tooLarge: "The app's Package.resolved exceeds Guesthouse's supported size limit."
        }
    }
    public var recoveryMessage: String {
        switch self {
        case .unsupportedVersion, .unknownKind:
            "Check for a compatible Guesthouse build and supported Xcode package settings."
        default:
            "Inspect the app's package settings, resolve packages in Xcode and review the resulting lockfile before continuing."
        }
    }
    public var recoveryActions: [RecoveryAction] { [.inspectState, .openSettings, .cancel] }
    public var errorDescription: String? { userMessage }
}
