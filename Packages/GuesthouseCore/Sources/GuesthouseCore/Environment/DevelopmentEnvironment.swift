import Foundation

/// One app-managed development Mac: the persistent record behind a dashboard card.
///
/// Named `DevelopmentEnvironment` rather than `Environment` to avoid clashing with SwiftUI's
/// `Environment` property wrapper in the GUI target. Runtime state (running, ready, IP) is
/// deliberately absent: it is reconciled from the live VM on every launch and never trusted
/// from disk (MVP-PLAN.md §3, "Application components").
public struct DevelopmentEnvironment: Codable, Hashable, Sendable, Identifiable {
    public var schemaVersion: SchemaVersion
    public let id: EnvironmentID
    public var name: String
    public let createdAt: Date
    public var preset: ResourcePreset
    /// Logical guest disk capacity. Starts at the preset's value and may diverge after a resize.
    public var guestDiskBytes: UInt64

    public init(
        id: EnvironmentID = EnvironmentID(),
        name: String,
        createdAt: Date = Date(),
        preset: ResourcePreset = .recommended,
        guestDiskBytes: UInt64? = nil,
        schemaVersion: SchemaVersion = .current
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.preset = preset
        self.guestDiskBytes = guestDiskBytes ?? preset.diskBytes
    }

    /// The Tart VM name that belongs to this environment.
    public var tartVMName: String { id.tartVMName }

    /// Reads a persisted record. A file that is not one becomes an actionable error rather
    /// than a decoder's internal complaint, and a record from a newer Guesthouse is refused
    /// instead of being reinterpreted.
    public static func decode(_ data: Data, using decoder: JSONDecoder = JSONDecoder()) throws(EnvironmentRecordError) -> DevelopmentEnvironment {
        let environment: DevelopmentEnvironment
        do {
            environment = try decoder.decode(DevelopmentEnvironment.self, from: data)
        } catch {
            throw .malformed
        }
        guard environment.schemaVersion <= .current else {
            throw .unsupportedSchemaVersion(environment.schemaVersion.rawValue)
        }
        return environment
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
