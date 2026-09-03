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

    /// The app-managed Tart VM name derived from this identity, for example
    /// `guesthouse-1a2b3c4d-0000-4000-8000-000000000000`.
    ///
    /// Uses the whole UUID so two environments can never share a VM bundle: lifecycle
    /// operations address VMs by this name, and a truncated identifier could start, preserve,
    /// or delete the wrong environment. The `guesthouse-` prefix marks app-managed VMs in
    /// `tart list`.
    public var tartVMName: String {
        "guesthouse-\(uuid.uuidString.lowercased())"
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
