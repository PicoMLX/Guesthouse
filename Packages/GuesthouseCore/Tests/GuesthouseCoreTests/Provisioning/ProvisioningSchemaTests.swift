import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningSchemaTests {
    @Test func unchangedProvisioningLayoutKeepsItsOwnVersion() throws {
        // A literal historical record must remain readable when an unrelated format changes
        // SchemaVersion.current. The epoch-bump integration probe also runs this test.
        let fixture = Data(#"{"schemaVersion":1,"stage":"preflight","issuedEffects":0,"status":{"notStarted":{}}}"#.utf8)
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: fixture)

        #expect(ProvisioningState.currentSchema.rawValue == 1)
        #expect(ProvisioningState.initial.schemaVersion.rawValue == 1)
        #expect(restored == .initial)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(encoded["schemaVersion"] as? Int == 1)
    }

    @Test(arguments: ["0", "-1", "2", "999", "true", #""1""#])
    func unsupportedProvisioningLayoutsAreRejected(version: String) {
        let fixture = Data("{\"schemaVersion\":\(version),\"stage\":\"preflight\",\"issuedEffects\":0,\"status\":{\"notStarted\":{}}}".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProvisioningState.self, from: fixture)
        }
    }
}
