import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ResolvedRegistryIdentityTests {
    private func data(_ identity: String, format: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": format, "pins": [[
            "identity": identity, "kind": "registry", "location": "", "state": ["version": "1.2.3"]
        ]]])
    }
    @Test(arguments: [2, 3], ["scope.library", "SCOPE-2.Lib_Name-3", "1.2", String(repeating: "s", count: 39) + "." + String(repeating: "n", count: 100)])
    func acceptsScopedRegistryIdentities(_ format: Int, identity: String) throws {
        let file = try ResolvedPackagesFile.decode(data(identity, format: format))
        #expect(file.pins.first?.identity.rawValue == identity.lowercased())
    }
    @Test(arguments: [2, 3], ["library", ".library", "scope.", "scope.name.extra", "a_b.library", "-scope.library", "scope-.library", "a--b.library", "scope._name", "scope.name-", "scope.na__me", "scope.na-_me", "scopé.library", "scope.lib/name", String(repeating: "s", count: 40) + ".name", "scope." + String(repeating: "n", count: 101)])
    func malformedRegistryPinsRejectTheWholeLockfile(_ format: Int, identity: String) throws {
        #expect(throws: ResolvedPackagesError.malformed(.identity)) { try ResolvedPackagesFile.decode(data(identity, format: format)) }
    }
}
