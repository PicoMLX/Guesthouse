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
}
