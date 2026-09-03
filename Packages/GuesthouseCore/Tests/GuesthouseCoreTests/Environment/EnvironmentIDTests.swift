import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct EnvironmentIDTests {
    @Test func tartVMNameUsesFirstEightHexCharactersLowercased() throws {
        let uuid = try #require(UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000000"))
        #expect(EnvironmentID(uuid: uuid).tartVMName == "guesthouse-1a2b3c4d")
    }

    @Test func distinctEnvironmentsGetDistinctVMNames() {
        #expect(EnvironmentID().tartVMName != EnvironmentID().tartVMName)
    }

    @Test func encodesAsBareUUIDString() throws {
        let id = EnvironmentID()
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(id.uuid.uuidString)\"")
        #expect(try JSONDecoder().decode(EnvironmentID.self, from: data) == id)
    }
}
