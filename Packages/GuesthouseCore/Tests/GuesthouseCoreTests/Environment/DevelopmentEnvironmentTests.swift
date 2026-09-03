import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct DevelopmentEnvironmentTests {
    @Test func roundTripsThroughJSONWithSchemaVersion() throws {
        let environment = DevelopmentEnvironment(
            name: "Dev Mac",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(environment)
        let decoded = try JSONDecoder().decode(DevelopmentEnvironment.self, from: data)
        #expect(decoded == environment)
        #expect(decoded.schemaVersion == .current)

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == SchemaVersion.current.rawValue)
        #expect(json["id"] as? String == environment.id.uuid.uuidString)
    }

    @Test func guestDiskDefaultsToPresetAndCanDiverge() {
        let defaulted = DevelopmentEnvironment(name: "A")
        #expect(defaulted.guestDiskBytes == ResourcePreset.recommended.diskBytes)

        let resized = DevelopmentEnvironment(name: "B", guestDiskBytes: 200 * ResourcePreset.gigabyte)
        #expect(resized.guestDiskBytes == 200 * ResourcePreset.gigabyte)
        #expect(resized.preset.diskBytes == ResourcePreset.recommended.diskBytes)
    }

    @Test func vmNameComesFromIdentity() {
        let environment = DevelopmentEnvironment(name: "C")
        #expect(environment.tartVMName == environment.id.tartVMName)
    }

    @Test func schemaVersionsCompare() {
        #expect(SchemaVersion(1) < SchemaVersion(2))
        #expect(SchemaVersion.current.description == "v\(SchemaVersion.current.rawValue)")
    }
}
