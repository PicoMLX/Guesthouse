import Foundation
import GuesthouseCore
import Testing

@Suite struct SnapshotMigratorTests {
    struct TransformFailure: Error {}

    @Test func currentDataIsReturnedByteForByte() throws {
        let source = Data("{ \"schemaVersion\" : 2, \"unknownField\": \"test-only\" }\n".utf8)
        let result = try SnapshotMigrator.standard.migrate(source)
        #expect(result.data == source)
        #expect(result.from == SchemaVersion(2))
        #expect(SnapshotMigrator.standard.current == EnvironmentsSnapshot.currentSchema)
    }

    @Test(arguments: [UInt64(9_223_372_036_854_775_808), UInt64.max - 1, UInt64.max])
    func currentSnapshotsKeepLargeCounterBytesAndOutstandingIdentity(counter: UInt64) throws {
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: Date(timeIntervalSince1970: 0))
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let state = ProvisioningState(stage: .first, status: .awaitingInspection(EffectToken(counter)), issuedEffects: counter)
        let original = EnvironmentsSnapshot(environments: [environment], slots: slots, provisioning: [environment.id: state])
        let source = try JSONEncoder().encode(original)
        let result = try SnapshotMigrator.standard.migrate(source)
        #expect(result.data == source)
        #expect(result.from == EnvironmentsSnapshot.currentSchema)
        let restored = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: result.data)
        #expect(restored == original)
        #expect(restored.provisioning[environment.id]?.issuedEffects == counter)
        #expect(restored.provisioning[environment.id]?.status.pendingEffect == EffectToken(counter))
    }

    @Test(arguments: [
        ("{}", SchemaVersion.unversioned),
        ("{\"schemaVersion\":1}", SchemaVersion(1)!),
    ])
    func standardDoesNotRestampPrototypeRecords(json: String, version: SchemaVersion) {
        #expect(throws: StateStoreError.migrationMissing(from: version)) {
            try SnapshotMigrator.standard.migrate(Data(json.utf8))
        }
    }

    @Test(arguments: [3, 99, Int.max])
    func futureVersionIsRefusedBeforeItsRecordShapeIsRead(version: Int) {
        #expect(throws: StateStoreError.newerSchemaVersion(found: SchemaVersion(version)!, current: SchemaVersion(2)!)) {
            try SnapshotMigrator.standard.migrate(Data("{\"schemaVersion\":\(version)}".utf8))
        }
    }

    @Test(arguments: ["true", "false", "null", "\"2\"", "0", "-1", "2.5", "9223372036854775808"])
    func malformedVersionIsNotTreatedAsUnversioned(value: String) {
        #expect(throws: StateStoreError.corruptSnapshot) {
            try SnapshotMigrator.standard.migrate(Data("{\"schemaVersion\":\(value)}".utf8))
        }
    }

    @Test(arguments: ["", "{", "[]", "null", "42", "\"document\"", "{\"schemaVersion\":2} trailing"])
    func malformedDocumentsProduceAClosedFailure(json: String) {
        #expect(throws: StateStoreError.corruptSnapshot) {
            try SnapshotMigrator.standard.migrate(Data(json.utf8))
        }
    }

    @Test func explicitTransformsRunInVersionOrderNotRegistrationOrder() throws {
        let migrator = SnapshotMigrator(migrations: [
            .init(from: SchemaVersion(1)!) { data in
                var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                try #require(object["firstStep"] as? Bool == true)
                object["schemaVersion"] = 2
                object["secondStep"] = true
                return try JSONSerialization.data(withJSONObject: object)
            },
            .init(from: .unversioned) { data in
                var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                object["schemaVersion"] = 1
                object["firstStep"] = true
                return try JSONSerialization.data(withJSONObject: object)
            },
        ])
        let source = Data("{\"retained\":\"test-only-value\"}".utf8)
        let result = try migrator.migrate(source)
        let object = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        #expect(result.from == .unversioned)
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["firstStep"] as? Bool == true)
        #expect(object["secondStep"] as? Bool == true)
        #expect(object["retained"] as? String == "test-only-value")
        #expect(source == Data("{\"retained\":\"test-only-value\"}".utf8))
    }

    @Test func aGapAfterOneStepDoesNotSkipToTheTarget() {
        let migrator = SnapshotMigrator(current: SchemaVersion(3)!, migrations: [
            .init(from: SchemaVersion(1)!) { _ in Data("{\"schemaVersion\":2}".utf8) },
        ])
        #expect(throws: StateStoreError.migrationMissing(from: SchemaVersion(2)!)) {
            try migrator.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }

    @Test(arguments: [
        ("{}", SchemaVersion.unversioned),
        ("{\"schemaVersion\":1}", SchemaVersion(1)!),
        ("{\"schemaVersion\":3}", SchemaVersion(3)!),
    ])
    func transformsMustProduceExactlyTheNextVersion(json: String, produced: SchemaVersion) {
        let migrator = SnapshotMigrator(migrations: [
            .init(from: SchemaVersion(1)!) { _ in Data(json.utf8) },
        ])
        #expect(throws: StateStoreError.migrationProducedWrongVersion(from: SchemaVersion(1)!, produced: produced)) {
            try migrator.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }

    @Test(arguments: ["{", "[]", "{\"schemaVersion\":false}"])
    func malformedTransformOutputIsRefused(json: String) {
        let migrator = SnapshotMigrator(migrations: [
            .init(from: SchemaVersion(1)!) { _ in Data(json.utf8) },
        ])
        #expect(throws: StateStoreError.corruptSnapshot) {
            try migrator.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }

    @Test func anArbitraryTransformErrorCannotEscape() {
        let migrator = SnapshotMigrator(migrations: [
            .init(from: SchemaVersion(1)!) { _ in
                throw NSError(domain: "test-only-migration", code: 1, userInfo: [NSLocalizedDescriptionKey: "test-only-underlying-text"])
            },
        ])
        #expect(throws: StateStoreError.migrationFailed(from: SchemaVersion(1)!)) {
            try migrator.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }

    @Test func aClosedTransformFailureRetainsItsCategory() {
        let migrator = SnapshotMigrator(migrations: [
            .init(from: SchemaVersion(1)!) { _ in throw StateStoreError.corruptSnapshot },
        ])
        #expect(throws: StateStoreError.corruptSnapshot) {
            try migrator.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }

    @Test(arguments: ["{", "{\"schemaVersion\":1}", "{\"schemaVersion\":2}"])
    func duplicateStepsFailBeforeParsingOrApplying(json: String) {
        let migration = SnapshotMigrator.Migration(from: SchemaVersion(1)!) { _ in throw TransformFailure() }
        let migrator = SnapshotMigrator(migrations: [migration, migration])
        #expect(throws: StateStoreError.duplicateMigration(from: SchemaVersion(1)!)) {
            try migrator.migrate(Data(json.utf8))
        }
    }

    @Test func currentEnvelopeRunsNoTransformAndStillRequiresRecordValidation() throws {
        let migrator = SnapshotMigrator(migrations: [
            .init(from: SchemaVersion(1)!) { _ in throw TransformFailure() },
            .init(from: SchemaVersion(2)!) { _ in throw TransformFailure() },
        ])
        let source = Data("{\"schemaVersion\":2}".utf8)
        let result = try migrator.migrate(source)
        #expect(result.data == source)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EnvironmentsSnapshot.self, from: result.data) }
        let valid = try JSONEncoder().encode(EnvironmentsSnapshot.empty)
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrator.migrate(valid).data) == .empty)
    }
}
