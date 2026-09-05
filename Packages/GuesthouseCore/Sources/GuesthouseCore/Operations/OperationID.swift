import Foundation

/// Identity of one runtime operation (start, stop, import, publish).
///
/// Persisted in the operation journal before the operation is reported as started, so an
/// interrupted operation can be found again and reconciled rather than replayed
/// (MVP-PLAN.md §3, "Application components").
public struct OperationID: Hashable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init(uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString }
}

extension OperationID: Codable {
    public init(from decoder: any Decoder) throws {
        uuid = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }
}
