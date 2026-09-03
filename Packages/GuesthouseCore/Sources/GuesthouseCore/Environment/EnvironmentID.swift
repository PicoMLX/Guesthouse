import Foundation

/// Persistent identity of a development environment.
///
/// Always a UUID. Never an IP address, a VM name, or a display name: those change over the
/// life of an environment, the UUID does not (MVP-PLAN.md §3, "Local storage").
public struct EnvironmentID: Hashable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init(uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    /// The app-managed Tart VM name derived from this identity, for example `guesthouse-1a2b3c4d`.
    ///
    /// Stable for the life of the environment. Eight hex characters are enough to keep the
    /// two app-managed VMs (MVP-PLAN.md §1) apart and to recognize them in `tart list`.
    public var tartVMName: String {
        let hex = uuid.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "guesthouse-\(hex.prefix(8))"
    }

    public var description: String { uuid.uuidString }
}

extension EnvironmentID: Codable {
    public init(from decoder: any Decoder) throws {
        uuid = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }
}
