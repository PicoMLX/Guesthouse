import Foundation

/// Guesthouse-generated identity used to reconcile an interrupted operation, never a guest label.
public struct OperationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID
    public init(uuid: UUID = UUID()) { self.uuid = uuid }
    public var description: String { uuid.uuidString }

    public init(from decoder: any Decoder) throws {
        uuid = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }
}
