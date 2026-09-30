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
    /// Format 4 retains process ownership evidence. Older writers must refuse it rather
    /// than silently discard identities. Formats 2 and 3 have explicit migrations.
    public static let currentSchema = SchemaVersion(4)!
    public var schemaVersion: SchemaVersion
    public var environments: [DevelopmentEnvironment]
    public var slots: VMSlotInventory
    public var provisioning: [EnvironmentID: ProvisioningState]
    /// Nil means unselected/unknown, never permission to infer a replacement for saved work.
    public var storageSelection: HostStorageSelection?
    /// Historical evidence only. An absent record never proves that an environment is stopped.
    /// Runtime inspection must reconcile these identities before reporting live state (§4).
    public var processIdentities: [EnvironmentID: ProcessIdentity]

    public init(
        schemaVersion: SchemaVersion = EnvironmentsSnapshot.currentSchema,
        environments: [DevelopmentEnvironment] = [],
        slots: VMSlotInventory = VMSlotInventory(),
        provisioning: [EnvironmentID: ProvisioningState] = [:],
        storageSelection: HostStorageSelection? = nil,
        processIdentities: [EnvironmentID: ProcessIdentity] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.environments = environments
        self.slots = slots
        self.provisioning = provisioning
        self.storageSelection = storageSelection
        self.processIdentities = processIdentities
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, environments, slots, provisioning, storageSelection, processIdentities
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, expectedVersion: Self.currentSchema)
    }

    private init(from decoder: any Decoder, expectedVersion: SchemaVersion) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(SchemaVersion.self, forKey: .schemaVersion)
        guard version == expectedVersion else {
            throw StateStoreError.unsupportedSnapshotVersion(found: version, current: Self.currentSchema)
        }
        self.init(
            schemaVersion: Self.currentSchema,
            environments: try c.decode([DevelopmentEnvironment].self, forKey: .environments),
            slots: try c.decode(VMSlotInventory.self, forKey: .slots),
            provisioning: try Self.decodeProvisioning(from: c),
            storageSelection: version.rawValue >= 3
                ? try c.decodeIfPresent(HostStorageSelection.self, forKey: .storageSelection) : nil,
            processIdentities: version.rawValue >= 4 ? try Self.decodeProcessIdentities(from: c) : [:]
        )
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.userMessage))
        }
    }

    /// Decode the known format-2 record shape before upgrading; never invent a volume identity.
    /// Reusing typed decoding preserves UInt64 tokens and duplicate provisioning-key checks.
    static func migrateVersion2(_ data: Data) throws -> Data {
        struct Version2: Decodable {
            let snapshot: EnvironmentsSnapshot
            init(from decoder: any Decoder) throws {
                snapshot = try EnvironmentsSnapshot(from: decoder, expectedVersion: SchemaVersion(2)!)
            }
        }
        do {
            let snapshot = try JSONDecoder().decode(Version2.self, from: data).snapshot
            return try JSONEncoder().encode(Version3Encoding(snapshot: snapshot))
        }
        catch let failure as StateStoreError { throw failure }
        catch { throw StateStoreError.corruptSnapshot }
    }

    /// Upgrade one version at a time, preserving the selected volume and exact typed counters.
    static func migrateVersion3(_ data: Data) throws -> Data {
        struct Version3: Decodable {
            let snapshot: EnvironmentsSnapshot
            init(from decoder: any Decoder) throws {
                snapshot = try EnvironmentsSnapshot(from: decoder, expectedVersion: SchemaVersion(3)!)
            }
        }
        do { return try JSONEncoder().encode(JSONDecoder().decode(Version3.self, from: data).snapshot) }
        catch let failure as StateStoreError { throw failure }
        catch { throw StateStoreError.corruptSnapshot }
    }

    private struct Version3Encoding: Encodable {
        let snapshot: EnvironmentsSnapshot
        func encode(to encoder: any Encoder) throws { try snapshot.encode(to: encoder, version: SchemaVersion(3)!) }
    }

    public func encode(to encoder: any Encoder) throws {
        try encode(to: encoder, version: Self.currentSchema)
    }

    private func encode(to encoder: any Encoder, version: SchemaVersion) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .schemaVersion)
        try c.encode(environments, forKey: .environments)
        try c.encode(slots, forKey: .slots)
        try c.encode(provisioning, forKey: .provisioning)
        try c.encodeIfPresent(storageSelection, forKey: .storageSelection)
        if version.rawValue >= 4 { try c.encode(processIdentities, forKey: .processIdentities) }
    }

    private static func decodeProcessIdentities(from container: KeyedDecodingContainer<CodingKeys>) throws -> [EnvironmentID: ProcessIdentity] {
        let object = try container.nestedContainer(keyedBy: UUIDKey.self, forKey: .processIdentities)
        var identities: [EnvironmentID: ProcessIdentity] = [:]
        for key in object.allKeys {
            guard let id = EnvironmentID(codingKey: key) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: object, debugDescription: "A process key is not a development Mac identifier.")
            }
            let identity = try object.decode(ProcessIdentity.self, forKey: key)
            guard identities.updateValue(identity, forKey: id) == nil else {
                throw DecodingError.dataCorruptedError(forKey: key, in: object, debugDescription: "Two process entries name one development Mac.")
            }
        }
        return identities
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
        guard Set(processIdentities.keys).isSubset(of: slotIDs) else {
            throw .inconsistentSnapshot(reason: .unknownProcessEnvironment)
        }
        for (id, identity) in processIdentities {
            guard id == identity.environmentID, identity.isConsistent else {
                throw .inconsistentSnapshot(reason: .processIdentity)
            }
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
