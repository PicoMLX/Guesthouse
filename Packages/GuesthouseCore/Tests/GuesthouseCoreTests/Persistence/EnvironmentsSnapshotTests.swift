import Foundation
import GuesthouseCore
import Testing

@Suite struct EnvironmentsSnapshotTests {
    let environment = DevelopmentEnvironment(
        id: EnvironmentID(uuid: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!),
        name: "Dev", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.123456789)
    )

    func sample() throws -> EnvironmentsSnapshot {
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        return EnvironmentsSnapshot(environments: [environment], slots: slots, provisioning: [environment.id: .initial])
    }

    func object(_ snapshot: EnvironmentsSnapshot) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    }

    func rejected(_ snapshot: EnvironmentsSnapshot, _ reason: StateStoreError.SnapshotInconsistency) {
        #expect(throws: StateStoreError.inconsistentSnapshot(reason: reason)) { try snapshot.validate() }
        #expect(throws: StateStoreError.inconsistentSnapshot(reason: reason)) { try JSONEncoder().encode(snapshot) }
    }

    @Test func roundTripPreservesDatesAndIndependentRecordVersions() throws {
        let original = try sample()
        let restored = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.environments[0].createdAt == environment.createdAt)
        #expect(restored.schemaVersion.rawValue == 2)
        #expect(restored.environments[0].schemaVersion.rawValue == 1)
        #expect(restored.provisioning[environment.id]?.schemaVersion.rawValue == 2)
        let json = try object(original)
        let provisioning = try #require(json["provisioning"] as? [String: Any])
        #expect(Set(provisioning.keys) == [environment.id.uuid.uuidString])
        let slots = try #require(json["slots"] as? [String: Any])
        #expect(slots["schemaVersion"] as? Int == 1)
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONEncoder().encode(EnvironmentsSnapshot.empty)) == .empty)
    }

    @Test(arguments: ProvisioningStage.allCases)
    func recoveredCheckpointWithoutOperationSurvivesSnapshot(stage: ProvisioningStage) throws {
        var original = try sample()
        let checkpoint = Checkpoint(stage: stage, reachedAt: environment.createdAt)
        let write = EffectToken(7)
        original.provisioning[environment.id] = ProvisioningState(
            stage: stage, status: .persistingCheckpoint(checkpoint, operation: nil, write: write)
        )
        let decoded = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let restored = try #require(decoded.provisioning[environment.id])
        let acknowledged = try ProvisioningReducer.reduce(restored, .checkpointPersisted(write, checkpoint))
        #expect(acknowledged.state.status == .completed(checkpoint))
        #expect(acknowledged.effects.isEmpty)
    }

    @Test func inconsistentIdentityListsCannotBeEncoded() throws {
        rejected(EnvironmentsSnapshot(environments: [environment, environment]), .duplicateEnvironments)
        rejected(EnvironmentsSnapshot(environments: [environment]), .slotsDisagree)
        var foreign = try sample()
        foreign.provisioning[EnvironmentID()] = .initial
        rejected(foreign, .unknownProvisioningEnvironment)
    }

    @Test func aNestedEnvironmentVersionMustBeSupported() throws {
        var future = try sample()
        future.environments = [DevelopmentEnvironment(id: environment.id, name: "Dev", schemaVersion: SchemaVersion(99)!)]
        rejected(future, .environmentVersion)
        var json = try object(sample())
        var environments = try #require(json["environments"] as? [[String: Any]])
        environments[0]["schemaVersion"] = 99
        json["environments"] = environments
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test(arguments: [
        (UInt64(9_223_372_036_854_775_807), UInt64(9_223_372_036_854_775_808)),
        (9_223_372_036_854_775_808, 9_223_372_036_854_775_809),
        (UInt64.max - 1, UInt64.max),
        (UInt64.max, nil)
    ] as [(UInt64, UInt64?)])
    func fullRangeProvisioningCountersSurviveSnapshots(counter: UInt64, next: UInt64?) throws {
        var original = try sample()
        original.provisioning[environment.id] = ProvisioningState(
            stage: .first, status: .awaitingInspection(EffectToken(counter)), issuedEffects: counter
        )
        let restored = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        let state = try #require(restored.provisioning[environment.id])
        #expect(state.issuedEffects == counter)
        #expect(state.status.pendingEffect == EffectToken(counter))
        #expect(state.nextEffectToken?.value == next)
    }

    @Test(arguments: [1, 3, 99])
    func outerVersionDoesNotAuthorizeANestedProvisioningFormat(version: Int) throws {
        var json = try object(sample())
        json["provisioning"] = [environment.id.uuid.uuidString: ["schemaVersion": version]]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test(arguments: [
        (2, VMSlotError.corruptInventory(reason: .duplicateEnvironment)),
        (3, .corruptInventory(reason: .tooManySlots(found: 3, maximum: 2))),
    ])
    func malformedSlotInventoriesAreRefused(count: Int, expected: VMSlotError) throws {
        var json = try object(sample())
        var inventory = try #require(json["slots"] as? [String: Any])
        let slots = try #require(inventory["slots"] as? [[String: Any]])
        let slot = try #require(slots.first)
        inventory["slots"] = Array(repeating: slot, count: count)
        json["slots"] = inventory
        #expect(throws: expected) {
            try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test(arguments: ["-1", "18446744073709551616", "\"1\"", "null", "true", "1.5"])
    func malformedOrUnrepresentablePersistedCountersAreRefused(counter: String) throws {
        let original = try sample()
        var json = try object(original)
        var provisioning = try #require(json["provisioning"] as? [String: [String: Any]])
        let key = environment.id.uuid.uuidString
        var state = try #require(provisioning[key])
        // Insert the numeric token as text so the fixture itself never overflows UInt64
        // or rounds an out-of-range number through a floating-point intermediary.
        state["issuedEffects"] = "COUNTER_FIXTURE_MARKER"
        provisioning[key] = state
        json["provisioning"] = provisioning
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        let marker = "\"COUNTER_FIXTURE_MARKER\""
        try #require(encoded.components(separatedBy: marker).count == 2)
        let control = Data(encoded.replacingOccurrences(of: marker, with: "0").utf8)
        let restored = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: control)
        try #require(restored == original)
        let data = Data(encoded.replacingOccurrences(of: marker, with: counter).utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnvironmentsSnapshot.self, from: data)
        }
    }

    @Test(arguments: [1, 3, 99])
    func unsupportedOuterFormatsAreRefusedBeforeReadingTheirShape(version: Int) throws {
        let schema = try #require(SchemaVersion(version))
        let error = StateStoreError.unsupportedSnapshotVersion(found: schema, current: EnvironmentsSnapshot.currentSchema)
        #expect(throws: error) {
            try JSONDecoder().decode(EnvironmentsSnapshot.self, from: Data("{\"schemaVersion\":\(version)}".utf8))
        }
        var changed = try sample()
        changed.schemaVersion = schema
        #expect(throws: error) { try JSONEncoder().encode(changed) }
    }

    @Test(arguments: ["{}", "{\"schemaVersion\":0}", "{\"schemaVersion\":-1}", "{\"schemaVersion\":false}", "{\"schemaVersion\":\"2\"}", "{\"schemaVersion\":2.5}"])
    func malformedOrUnversionedEnvelopesAreNotUpgraded(json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EnvironmentsSnapshot.self, from: Data(json.utf8)) }
    }

    @Test func duplicateUUIDSpellingsCannotDiscardAProvisioningRecord() throws {
        var json = try object(sample())
        var provisioning = try #require(json["provisioning"] as? [String: Any])
        let upper = environment.id.uuid.uuidString.uppercased()
        let lower = upper.lowercased()
        #expect(upper != lower)
        let state = try #require(provisioning[upper] as? [String: Any])
        provisioning[lower] = state
        json["provisioning"] = provisioning
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test(arguments: ["not-a-uuid", "00000000-0000-4000-8000-000000000000"])
    func invalidOrUnregisteredProvisioningKeysAreRefused(key: String) throws {
        var json = try object(sample())
        let provisioning = try #require(json["provisioning"] as? [String: Any])
        json["provisioning"] = [key: try #require(provisioning.values.first)]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func unknownFieldsAreNotReencoded() throws {
        let original = try sample()
        var json = try object(original)
        json["rawOutput"] = "test-only-discarded-output"
        let restored = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored == original)
        #expect(Set(try object(restored).keys) == ["schemaVersion", "environments", "slots", "provisioning"])
    }
}
