import Foundation

/// One app-managed development Mac: the persistent record behind a dashboard card.
///
/// Named `DevelopmentEnvironment` rather than `Environment` to avoid clashing with SwiftUI's
/// `Environment` property wrapper in the GUI target. Runtime state (running, ready, IP) is
/// deliberately absent: it is reconciled from the live VM on every launch and never trusted
/// from disk (MVP-PLAN.md §3, "Application components").
public struct DevelopmentEnvironment: Codable, Hashable, Sendable, Identifiable {
    public private(set) var schemaVersion: SchemaVersion
    public let id: EnvironmentID
    public var name: String
    public let createdAt: Date
    public private(set) var preset: ResourcePreset
    /// Logical guest disk capacity. Starts at the preset's value and may diverge after a resize.
    /// Always positive: a development Mac with no disk is not a configuration the runtime can
    /// be asked for, so it cannot be constructed, decoded, or assigned.
    public private(set) var guestDiskBytes: UInt64

    /// A `guestDiskBytes` of zero means the same thing as none at all: use the preset's
    /// capacity. The preset validates its own values, so a constructed environment always
    /// carries a disk the runtime can be asked for.
    public init(
        id: EnvironmentID = EnvironmentID(),
        name: String,
        createdAt: Date = Date(),
        preset: ResourcePreset = .recommended,
        guestDiskBytes: UInt64? = nil,
        schemaVersion: SchemaVersion = .current
    ) {
        let disk = (guestDiskBytes ?? 0) > 0 ? guestDiskBytes! : preset.diskBytes
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.preset = preset
        self.guestDiskBytes = disk
    }

    /// Decoded by hand so a persisted zero is refused rather than carried into the runtime.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        id = try container.decode(EnvironmentID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        preset = try container.decode(ResourcePreset.self, forKey: .preset)
        let disk = try container.decode(UInt64.self, forKey: .guestDiskBytes)
        guard disk > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .guestDiskBytes, in: container, debugDescription: "guest disk capacity must be positive")
        }
        guestDiskBytes = disk
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, createdAt, preset, guestDiskBytes
    }

    /// Resizes the guest disk. A resize to nothing is refused the same way construction is.
    public mutating func setGuestDiskBytes(_ bytes: UInt64) -> Bool {
        guard bytes > 0 else { return false }
        guestDiskBytes = bytes
        return true
    }

    /// Replaces the resource preset. The preset type validates itself, so this only records it.
    public mutating func setPreset(_ preset: ResourcePreset) {
        self.preset = preset
    }

    /// The Tart VM name that belongs to this environment.
    public var tartVMName: String { id.tartVMName }

    /// Reads a persisted record. A file that is not one becomes an actionable error rather
    /// than a decoder's internal complaint, and a record from a newer Guesthouse is refused
    /// instead of being reinterpreted.
    public static func decode(_ data: Data, using decoder: JSONDecoder = JSONDecoder()) throws(EnvironmentRecordError) -> DevelopmentEnvironment {
        // The version envelope is read on its own first. A newer record may have renamed or
        // retyped a field this build requires, and decoding the whole record would report
        // that as damage instead of as "written by a newer Guesthouse".
        let envelope: VersionEnvelope
        do {
            envelope = try decoder.decode(VersionEnvelope.self, from: data)
        } catch {
            throw .malformed
        }
        guard envelope.schemaVersion <= .current else {
            throw .unsupportedSchemaVersion(envelope.schemaVersion.rawValue)
        }
        do {
            return try decoder.decode(DevelopmentEnvironment.self, from: data)
        } catch {
            throw .malformed
        }
    }

    /// Just the version field, so a record's format can be established before its shape is.
    private struct VersionEnvelope: Decodable {
        let schemaVersion: SchemaVersion
    }
}

/// A persisted environment record could not be used.
public enum EnvironmentRecordError: Error, Hashable, Sendable, LocalizedError {
    case malformed
    case unsupportedSchemaVersion(Int)

    public var userMessage: String {
        switch self {
        case .malformed:
            "One of Guesthouse's development Mac records could not be read."
        case .unsupportedSchemaVersion(let version):
            "A development Mac record was written by a newer Guesthouse (format \(version)). Update Guesthouse to open it."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .malformed:
            "Guesthouse will inspect the virtual machines that actually exist and rebuild its records from them; nothing is started or deleted until it has."
        case .unsupportedSchemaVersion:
            "Update Guesthouse, or use the version that wrote the record."
        }
    }

    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }
}
