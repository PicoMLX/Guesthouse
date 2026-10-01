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
    /// so its size is bounded before the Codable reader materializes the document and
    /// the pin arrays are built from it.
    public static let maximumEncodedSize = 1024 * 1024

    public static func decode(_ data: Data) throws(ResolvedPackagesError) -> ResolvedPackagesFile {
        guard data.count <= Self.maximumEncodedSize else { throw .tooLarge }
        do { return try JSONDecoder().decode(Document.self, from: data).value }
        catch let error as ResolvedPackagesError { throw error }
        catch { throw .notJSON }
    }

    // One Codable reader, matching SwiftPM's semantics for duplicate keys at every depth.
    // Never combine its version selection with JSONSerialization's different key selection.
    private struct Document: Decodable {
        let value: ResolvedPackagesFile
        enum Keys: String, CodingKey { case version, pins, originHash }
        init(from decoder: any Decoder) throws {
            guard let fields = try? decoder.container(keyedBy: Keys.self) else { throw ResolvedPackagesError.notJSON }
            guard let version = try? fields.decode(Int.self, forKey: .version) else { throw ResolvedPackagesError.missingVersion }
            guard version == 2 || version == 3 else { throw ResolvedPackagesError.unsupportedVersion }
            if version == 3 { _ = try fields.resolvedString(forKey: .originHash, field: .originHash) }
            let pins = try fields.resolvedValue([DecodedPin].self, forKey: .pins, field: .pins).map(\.value)
            guard Set(pins.map(\.identity)).count == pins.count else { throw ResolvedPackagesError.malformed(.duplicateIdentity) }
            value = ResolvedPackagesFile(version: version, pins: pins)
        }
    }

    private struct DecodedPin: Decodable {
        let value: Pin
        enum Keys: String, CodingKey { case identity, kind, location, state }
        init(from decoder: any Decoder) throws {
            guard let fields = try? decoder.container(keyedBy: Keys.self) else { throw ResolvedPackagesError.malformed(.pins) }
            let identityText = try fields.resolvedValue(String.self, forKey: .identity, field: .identity)
            guard let identity = PackageIdentity(resolvedIdentity: identityText) else { throw ResolvedPackagesError.malformed(.identity) }
            let kindText = try fields.resolvedValue(String.self, forKey: .kind, field: .kind)
            guard let kind = Pin.Kind(rawValue: kindText) else { throw ResolvedPackagesError.unknownKind }
            // Check the input spelling: Unicode case conversion can produce ASCII.
            if kind == .registry, !ResolvedPackagesFile.isRegistryIdentity(identityText) {
                throw ResolvedPackagesError.malformed(.identity)
            }
            let location = try fields.resolvedValue(String.self, forKey: .location, field: .location)
            // Syntactic Unix path check only; no host inspection or rewriting.
            if kind == .localSourceControl, !location.hasPrefix("/") { throw ResolvedPackagesError.malformed(.location) }
            let state = try fields.resolvedValue(PinState.self, forKey: .state, field: .state)
            // Guesthouse's supported source-control layout requires a full nonzero commit ID.
            if kind != .registry, CommitSHA(state.revision ?? "") == nil { throw ResolvedPackagesError.malformed(.revision) }
            if let version = state.version, !ResolvedPackagesFile.isSemanticVersion(version) { throw ResolvedPackagesError.malformed(.semanticVersion) }
            if kind == .registry, state.version == nil { throw ResolvedPackagesError.malformed(.semanticVersion) }
            value = Pin(identity: identity, kind: kind, location: location, revision: state.revision, version: state.version, branch: state.branch)
        }
    }

    private struct PinState: Decodable {
        let revision: String?, version: String?, branch: String?
        enum Keys: String, CodingKey { case revision, version, branch }
        init(from decoder: any Decoder) throws {
            guard let fields = try? decoder.container(keyedBy: Keys.self) else { throw ResolvedPackagesError.malformed(.state) }
            revision = try fields.resolvedString(forKey: .revision, field: .revision)
            version = try fields.resolvedString(forKey: .version, field: .semanticVersion)
            branch = try fields.resolvedString(forKey: .branch, field: .branch)
        }
    }

    /// SwiftPM registry scope (1...39) and package name (1...100), separated by one dot.
    /// Names additionally allow underscores; neither part allows adjacent/edge punctuation.
    private static func isRegistryIdentity(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        func valid(_ part: Substring, limit: Int, underscore: Bool) -> Bool {
            guard (1...limit).contains(part.utf8.count) else { return false }
            var followsPunctuation = true
            for character in part {
                guard character.isASCII else { return false }
                if character.isLetter || character.isNumber { followsPunctuation = false }
                else if character == "-" || (underscore && character == "_") {
                    guard !followsPunctuation else { return false }
                    followsPunctuation = true
                } else { return false }
            }
            return !followsPunctuation
        }
        return valid(parts[0], limit: 39, underscore: false) && valid(parts[1], limit: 100, underscore: true)
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

}

private extension KeyedDecodingContainer {
    func resolvedValue<T: Decodable>(_ type: T.Type, forKey key: Key, field: ResolvedPackagesError.Field) throws -> T {
        do { return try decode(type, forKey: key) }
        catch let error as ResolvedPackagesError { throw error }
        catch { throw ResolvedPackagesError.malformed(field) }
    }
    func resolvedString(forKey key: Key, field: ResolvedPackagesError.Field) throws -> String? {
        do { return try decodeIfPresent(String.self, forKey: key) }
        catch { throw ResolvedPackagesError.malformed(field) }
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
