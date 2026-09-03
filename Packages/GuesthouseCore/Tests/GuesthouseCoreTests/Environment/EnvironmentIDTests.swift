import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct EnvironmentIDTests {
    @Test func tartVMNameUsesTheWholeUUIDLowercased() throws {
        let uuid = try #require(UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000000"))
        #expect(EnvironmentID(uuid: uuid).tartVMName == "guesthouse-1a2b3c4d-0000-4000-8000-000000000000")
    }

    @Test func environmentsSharingAUUIDPrefixStillGetDistinctVMNames() throws {
        let a = try #require(UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001"))
        let b = try #require(UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000002"))
        #expect(EnvironmentID(uuid: a).tartVMName != EnvironmentID(uuid: b).tartVMName)
    }

    @Test func encodesAsBareUUIDString() throws {
        let id = EnvironmentID()
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(id.uuid.uuidString)\"")
        #expect(try JSONDecoder().decode(EnvironmentID.self, from: data) == id)
    }
}
