import Foundation
import GuesthouseCore
import Testing

@Suite struct HostStorageSelectionTests {
    @Test func selectionRoundTripsAndRejectsZeroOrMalformedIdentity() throws {
        let selection = try #require(HostStorageSelection(volumeID: UUID()))
        let snapshot = EnvironmentsSnapshot(storageSelection: selection)
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        for value in ["00000000-0000-0000-0000-000000000000", "invalid"] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(HostStorageSelection.self, from: Data("{\"volumeID\":\"\(value)\"}".utf8))
            }
        }
        #expect(HostStorageSelection(volumeID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) == nil)
    }

    @Test func formatTwoMigrationPreservesWorkAndUnknownEffectWithoutSelectingStorage() throws {
        let environment = DevelopmentEnvironment(name: "Saved work")
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let pending = ProvisioningState(stage: .first, status: .awaitingInspection(EffectToken(UInt64.max)), issuedEffects: UInt64.max)
        let expected = EnvironmentsSnapshot(environments: [environment], slots: slots, provisioning: [environment.id: pending])
        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let original = Data(json.replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":2").utf8)
        let migrated = try SnapshotMigrator.standard.migrate(original)
        #expect(migrated.from == SchemaVersion(2))
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrated.data) == expected)
        #expect(expected.storageSelection == nil)
        #expect(throws: StateStoreError.newerSchemaVersion(found: SchemaVersion(3)!, current: SchemaVersion(2)!)) {
            try SnapshotMigrator(current: SchemaVersion(2)!, migrations: []).migrate(migrated.data)
        }
    }

    @Test(arguments: [
        #"{"schemaVersion":2}"#,
        #"{"schemaVersion":2,"environments":[],"slots":{"slots":[]},"provisioning":{"invalid":{}}}"#,
    ])
    func formatTwoDamageIsNotRestamped(json: String) {
        #expect(throws: StateStoreError.corruptSnapshot) { try SnapshotMigrator.standard.migrate(Data(json.utf8)) }
    }
}
