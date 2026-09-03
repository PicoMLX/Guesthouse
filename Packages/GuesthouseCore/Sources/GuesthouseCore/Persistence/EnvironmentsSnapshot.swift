import Foundation

/// Everything the app remembers about its environments between launches.
///
/// Runtime facts (running, reachable, ready) are deliberately not here. On launch the
/// coordinator reconciles this snapshot against the real VM, guest, and journal state;
/// a saved "ready" is never proof (MVP-PLAN.md §3, "Application components").
public struct EnvironmentsSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: SchemaVersion
    public var environments: [DevelopmentEnvironment]
    public var slots: VMSlotInventory
    public var provisioning: [EnvironmentID: ProvisioningState]

    public init(
        schemaVersion: SchemaVersion = .current,
        environments: [DevelopmentEnvironment] = [],
        slots: VMSlotInventory = VMSlotInventory(),
        provisioning: [EnvironmentID: ProvisioningState] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.environments = environments
        self.slots = slots
        self.provisioning = provisioning
    }

    public static let empty = EnvironmentsSnapshot()
}

/// Lets `[EnvironmentID: Value]` encode as a JSON object keyed by UUID string.
extension EnvironmentID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringKey(uuid.uuidString) }

    public init?<T: CodingKey>(codingKey: T) {
        guard let uuid = UUID(uuidString: codingKey.stringValue) else { return nil }
        self.init(uuid: uuid)
    }

    private struct StringKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
