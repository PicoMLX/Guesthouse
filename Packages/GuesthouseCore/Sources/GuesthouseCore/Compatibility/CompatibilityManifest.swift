import Foundation

/// The versioned list of combinations Guesthouse has tested, shipped with the app
/// (MVP-PLAN.md §10, Phase 2: "Keep a versioned compatibility manifest").
///
/// A tested tuple is not the same as a verified one. A tested entry supports a range of host
/// macOS versions; its `verification`, if any, names the exact host version and build on
/// which a real Codex desktop connection was recorded, and only that exact host counts.
public struct CompatibilityManifest: Codable, Hashable, Sendable {
    public typealias Verification = ManifestConnectionVerification
    public typealias TestedTuple = TestedCompatibilityTuple
    public typealias KnownIncompatibility = CompatibilityIncompatibility
    /// Provider-aware manifest layout, independent of other persisted model epochs.
    public static let currentSchema = SchemaVersion(2)!
    public let schemaVersion: SchemaVersion
    /// Monotonic manifest revision, independent of the record schema.
    public let manifestVersion: Int
    public let notes: String?
    public let tested: [TestedTuple]
    public let incompatibilities: [KnownIncompatibility]

    public init(
        schemaVersion: SchemaVersion = Self.currentSchema,
        manifestVersion: Int,
        notes: String? = nil,
        tested: [TestedTuple],
        incompatibilities: [KnownIncompatibility] = []
    ) throws(CompatibilityManifestError) {
        guard schemaVersion == Self.currentSchema else {
            throw .unsupportedSchema(found: schemaVersion, supported: Self.currentSchema)
        }
        guard manifestVersion > 0 else { throw .malformedManifest }
        self.schemaVersion = schemaVersion
        self.manifestVersion = manifestVersion
        self.notes = notes
        self.tested = tested
        self.incompatibilities = incompatibilities
    }

    /// Refuses any schema this build cannot interpret: a newer document may carry a
    /// compatibility dimension this evaluator would silently ignore. The check lives here so
    /// that a plain `JSONDecoder().decode(CompatibilityManifest.self, from:)` enforces it too.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(SchemaVersion.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchema else {
            throw CompatibilityManifestError.unsupportedSchema(found: schemaVersion, supported: Self.currentSchema)
        }
        try self.init(
            schemaVersion: schemaVersion,
            manifestVersion: try c.decode(Int.self, forKey: .manifestVersion),
            notes: try c.decodeIfPresent(String.self, forKey: .notes),
            tested: try c.decode([TestedTuple].self, forKey: .tested),
            incompatibilities: try c.decode([KnownIncompatibility].self, forKey: .incompatibilities)
        )
    }

    /// The manifest shipped inside this package.
    public static func bundled() throws(CompatibilityManifestError) -> CompatibilityManifest {
        guard let url = Bundle.module.url(forResource: "compatibility-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            throw CompatibilityManifestError.unreadableManifest
        }
        return try decode(from: data)
    }

    /// Decodes a manifest, reporting every failure as something the user can act on rather than
    /// as a raw decoding fault: the only manifest the app reads is one it shipped with, so a
    /// failure here means the installation, not the document, is wrong.
    public static func decode(from data: Data) throws(CompatibilityManifestError) -> CompatibilityManifest {
        do {
            return try JSONDecoder().decode(CompatibilityManifest.self, from: data)
        } catch let error as CompatibilityManifestError {
            throw error
        } catch {
            throw CompatibilityManifestError.malformedManifest
        }
    }
}

public enum CompatibilityManifestError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedSchema(found: SchemaVersion, supported: SchemaVersion)
    /// The shipped resource is missing from the bundle or could not be read.
    case unreadableManifest
    /// The document is not a compatibility manifest this build can parse. What was found is
    /// deliberately not quoted; resource content does not belong in a user-facing message.
    case malformedManifest

    public var userMessage: String {
        switch self {
        case .unsupportedSchema(let found, let supported):
            "The compatibility list shipped with this copy of Guesthouse uses format \(found.rawValue), which this version reads as \(supported.rawValue). The app and its resources do not match; reinstall Guesthouse."
        case .unreadableManifest:
            "The compatibility list shipped with this copy of Guesthouse is missing or cannot be read. The installation is damaged; reinstall Guesthouse."
        case .malformedManifest:
            "The compatibility list shipped with this copy of Guesthouse is not a list this version can read. The installation is damaged; reinstall Guesthouse."
        }
    }

    public var recoveryActions: [RecoveryAction] { [.reinstallApp, .cancel] }
    public var errorDescription: String? { userMessage }
}
