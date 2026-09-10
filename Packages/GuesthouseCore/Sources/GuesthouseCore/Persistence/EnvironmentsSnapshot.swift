import Foundation

/// Everything the app remembers about its environments between launches.
///
/// Runtime facts (running, reachable, ready) are deliberately not here. On launch the
/// coordinator reconciles this snapshot against the real VM, guest, and journal state;
/// a saved "ready" is never proof (MVP-PLAN.md §3, "Application components").
///
/// A snapshot is consistent when every environment has exactly one slot and every slot
/// belongs to an environment, and no two environments share an identity (which would mean two
/// records controlling one VM). `validate()` runs before encoding and after decoding.
/// The concrete runtime store owns durability, permissions and preservation of rejected files.
public struct EnvironmentsSnapshot: Codable, Hashable, Sendable {
    /// Format 3 retains host storage identity. Older writers must refuse it rather than
    /// silently discard that identity. No older snapshot is re-stamped or rewritten.
    public static let currentSchema = SchemaVersion(3)!
    public var schemaVersion: SchemaVersion
    public var environments: [DevelopmentEnvironment]
    public var slots: VMSlotInventory
    public var provisioning: [EnvironmentID: ProvisioningState]
    /// Nil means unselected/unknown, never permission to infer a replacement for saved work.
    public var storageSelection: HostStorageSelection?

    public init(
        schemaVersion: SchemaVersion = EnvironmentsSnapshot.currentSchema,
        environments: [DevelopmentEnvironment] = [],
        slots: VMSlotInventory = VMSlotInventory(),
        provisioning: [EnvironmentID: ProvisioningState] = [:],
        storageSelection: HostStorageSelection? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.environments = environments
        self.slots = slots
        self.provisioning = provisioning
        self.storageSelection = storageSelection
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, environments, slots, provisioning, storageSelection
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(SchemaVersion.self, forKey: .schemaVersion)
        guard version == Self.currentSchema else {
            throw StateStoreError.unsupportedSnapshotVersion(found: version, current: Self.currentSchema)
        }
        self.init(
            schemaVersion: version,
            environments: try c.decode([DevelopmentEnvironment].self, forKey: .environments),
            slots: try c.decode(VMSlotInventory.self, forKey: .slots),
            provisioning: try Self.decodeProvisioning(from: c),
            storageSelection: try c.decodeIfPresent(HostStorageSelection.self, forKey: .storageSelection)
        )
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.userMessage))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(environments, forKey: .environments)
        try c.encode(slots, forKey: .slots)
        try c.encode(provisioning, forKey: .provisioning)
        try c.encodeIfPresent(storageSelection, forKey: .storageSelection)
    }

    /// Reads the provisioning object one key at a time instead of straight into a dictionary.
    /// Two spellings of one UUID — the same identifier in upper and lower case — are distinct
    /// JSON keys but the same `EnvironmentID`, so decoding into a dictionary would keep one
    /// entry and drop the other's provisioning checkpoint without a word. A document that names
    /// one development Mac twice is damaged, and is reported as such.
    private static func decodeProvisioning(from container: KeyedDecodingContainer<CodingKeys>) throws -> [EnvironmentID: ProvisioningState] {
        let object = try container.nestedContainer(keyedBy: UUIDKey.self, forKey: .provisioning)
        var provisioning: [EnvironmentID: ProvisioningState] = [:]
        for key in object.allKeys {
            guard let id = EnvironmentID(codingKey: key) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: object, debugDescription: "A provisioning key is not a development Mac identifier.")
            }
            let state = try object.decode(ProvisioningState.self, forKey: key)
            guard provisioning.updateValue(state, forKey: id) == nil else {
                throw DecodingError.dataCorruptedError(forKey: key, in: object, debugDescription: "two provisioning entries name one development Mac")
            }
        }
        return provisioning
    }

    private struct UUIDKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public static let empty = EnvironmentsSnapshot()

    public func validate() throws(StateStoreError) {
        guard schemaVersion == Self.currentSchema else {
            throw .unsupportedSnapshotVersion(found: schemaVersion, current: Self.currentSchema)
        }
        let ids = environments.map(\.id)
        guard Set(ids).count == ids.count else {
            throw .inconsistentSnapshot(reason: .duplicateEnvironments)
        }
        let slotIDs = Set(slots.slots.map(\.environmentID))
        guard slotIDs.count == slots.slots.count else {
            throw .inconsistentSnapshot(reason: .duplicateSlots)
        }
        guard slotIDs == Set(ids) else {
            throw .inconsistentSnapshot(reason: .slotsDisagree)
        }
        guard Set(provisioning.keys).isSubset(of: slotIDs) else {
            throw .inconsistentSnapshot(reason: .unknownProvisioningEnvironment)
        }
        // A record's own version is checked too. The outer version says what this build wrote;
        // an environment carrying a different one was never understood by whatever produced it
        // and must be migrated, not read or rewritten as if it were current.
        for environment in environments {
            guard environment.schemaVersion == SchemaVersion.current else {
                throw .inconsistentSnapshot(reason: .environmentVersion)
            }
        }
        // The values are checked the way their decoder checks them, so a snapshot is never
        // written that the next load would call corrupt.
        for state in provisioning.values {
            guard state.schemaVersion == ProvisioningState.currentSchema else {
                throw .inconsistentSnapshot(reason: .provisioningVersion)
            }
            guard state.isConsistent else {
                throw .inconsistentSnapshot(reason: .checkpointStage)
            }
            // ProvisioningState accepts the same full UInt64 range in memory and on disk.
            // Exhaustion refuses new reservations, not persistence of an outstanding effect.
            // Do not impose a second, smaller snapshot-only counter ceiling here.
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
