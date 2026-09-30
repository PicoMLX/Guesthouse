import Foundation

/// Retained identity for the runtime's fixed Application Support layout (MVP-PLAN.md §3).
/// This is metadata, not a current observation, GUI-selected path or write capability.
/// Only the runtime may establish it from its actual selected volume. Refreshes compare
/// against it; they never replace it with the identity currently found at the path.
public struct HostStorageSelection: Codable, Hashable, Sendable {
    public let volumeID: UUID

    public init?(volumeID: UUID) {
        guard volumeID.uuidString != "00000000-0000-0000-0000-000000000000" else { return nil }
        self.volumeID = volumeID
    }

    private enum CodingKeys: String, CodingKey { case volumeID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let volumeID = try container.decode(UUID.self, forKey: .volumeID)
        guard let value = Self(volumeID: volumeID) else {
            throw DecodingError.dataCorruptedError(forKey: .volumeID, in: container,
                debugDescription: "The saved storage-volume identity is invalid.")
        }
        self = value
    }
}
