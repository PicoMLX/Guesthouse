import Foundation

/// Everything the app remembers about its environments between launches.
///
/// Runtime facts (running, reachable, ready) are deliberately not here. On launch the
/// coordinator reconciles this snapshot against the real VM, guest, and journal state;
/// a saved "ready" is never proof (MVP-PLAN.md §3, "Application components").
///
/// A snapshot is consistent when every environment has exactly one slot and every slot
/// belongs to an environment, and no two environments share an identity (which would mean two
/// records controlling one Tart VM). `validate()` is applied when decoding and before saving.
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

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try c.decode(SchemaVersion.self, forKey: .schemaVersion),
            environments: try c.decode([DevelopmentEnvironment].self, forKey: .environments),
            slots: try c.decode(VMSlotInventory.self, forKey: .slots),
            provisioning: try c.decode([EnvironmentID: ProvisioningState].self, forKey: .provisioning)
        )
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.userMessage))
        }
    }

    public static let empty = EnvironmentsSnapshot()

    public func validate() throws(StateStoreError) {
        let ids = environments.map(\.id)
        guard Set(ids).count == ids.count else {
            throw .inconsistentSnapshot(reason: "two environments share one identity")
        }
        let slotIDs = Set(slots.slots.map(\.environmentID))
        guard slotIDs.count == slots.slots.count else {
            throw .inconsistentSnapshot(reason: "two slots share one environment")
        }
        guard slotIDs == Set(ids) else {
            throw .inconsistentSnapshot(reason: "environments and VM slots disagree")
        }
        guard Set(provisioning.keys).isSubset(of: slotIDs) else {
            throw .inconsistentSnapshot(reason: "provisioning state for an unknown environment")
        }
        // A record's own version is checked too. The outer version says what this build wrote;
        // an environment carrying a different one was never understood by whatever produced it
        // and must be migrated, not read or rewritten as if it were current.
        for environment in environments {
            guard environment.schemaVersion == SchemaVersion.current else {
                throw .inconsistentSnapshot(reason: "a development Mac record with another schema version")
            }
        }
        // The values are checked the way their decoder checks them, so a snapshot is never
        // written that the next load would call corrupt.
        for state in provisioning.values {
            guard state.schemaVersion == SchemaVersion.current else {
                throw .inconsistentSnapshot(reason: "provisioning state with another schema version")
            }
            guard state.isConsistent else {
                throw .inconsistentSnapshot(reason: "provisioning checkpoint does not match its stage")
            }
        }
    }
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
