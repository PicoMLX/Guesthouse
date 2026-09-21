import Foundation
import GuesthouseCore
import Testing

@Suite struct HostStorageSelectionTests {
    let volume = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!

    @Test(arguments: [false, true]) func snapshotRoundTripRetainsSelectionWithoutInventingOne(selected: Bool) throws {
        let record = try #require(HostStorageSelection(volumeID: volume))
        let selection = selected ? record : nil
        let value = EnvironmentsSnapshot(storageSelection: selection)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: data) == value)
        #expect(value.storageSelection?.volumeID == (selected ? volume : nil))
        #expect(value.schemaVersion == SchemaVersion(3))
    }

    @Test func emptyUUIDCannotBeSelected() {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        #expect(HostStorageSelection(volumeID: zero) == nil)
    }

    @Test(arguments: ["{}", "{\"volumeID\":null}", "{\"volumeID\":true}", "{\"volumeID\":\"invalid\"}",
                      "{\"volumeID\":\"00000000-0000-0000-0000-000000000000\"}"])
    func malformedSelectionCannotDecode(json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HostStorageSelection.self, from: Data(json.utf8)) }
    }

    @Test func selectionCarriesOnlyTheRetainedIdentity() throws {
        let input: [String: Any] = ["volumeID": volume.uuidString, "path": "/private-fixture-marker",
                                   "rawOutput": "private-fixture-marker", "verified": true]
        let value = try JSONDecoder().decode(HostStorageSelection.self, from: JSONSerialization.data(withJSONObject: input))
        let output = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(Set(output.keys) == ["volumeID"])
        #expect(output["volumeID"] as? String == volume.uuidString)
    }

    @Test func oldWritersCannotSilentlyDiscardTheBinding() throws {
        let value = EnvironmentsSnapshot(storageSelection: try #require(HostStorageSelection(volumeID: volume)))
        let bytes = try JSONEncoder().encode(value)
        let oldWriter = SnapshotMigrator(current: SchemaVersion(2)!, migrations: [])
        #expect(throws: StateStoreError.newerSchemaVersion(found: SchemaVersion(3)!, current: SchemaVersion(2)!)) {
            try oldWriter.migrate(bytes)
        }
    }
}
