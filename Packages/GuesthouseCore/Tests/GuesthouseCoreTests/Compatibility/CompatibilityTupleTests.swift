import Foundation
import GuesthouseCore
import Testing

struct CompatibilityTupleTests {
    static func tuple(provider: VMProvider = .lume, capabilities: [String] = ["remote-app-server"]) -> CompatibilityTuple {
        CompatibilityTuple(
            hostMacOSVersion: SemanticVersion([26, 4]), hostMacOSBuild: "25E20",
            codexDesktopVersion: "1.2.3", codexDesktopBuild: "1234", codexDesktopPath: "/Applications/Codex.app",
            runtimeProtocolVersion: 1, runtimeProvider: provider, runtimeVersion: "0.5.3",
            guestMacOSBuild: "25F84", xcodeBuild: "17F113", codexCLIVersion: "0.50.0",
            codexCLIPath: "/opt/homebrew/bin/codex", codexCLIInstallations: 1, codexCLICapabilities: capabilities,
            githubCLIVersion: "2.80.0", provisioningScriptVersion: "1"
        )
    }

    @Test(arguments: VMProvider.allCases)
    func fullyKnownObservationsRoundTripWithoutLosingIdentity(_ provider: VMProvider) throws {
        let expected = Self.tuple(provider: provider)
        let data = try JSONEncoder().encode(expected)
        #expect(try JSONDecoder().decode(CompatibilityTuple.self, from: data) == expected)
        let observed = try JSONDecoder().decode(ObservedTuple.self, from: data)
        #expect(observed.exact == expected)
        #expect(observed.unknownFields.isEmpty)
        #expect(try JSONDecoder().decode(ObservedTuple.self, from: JSONEncoder().encode(observed)) == observed)
    }

    @Test func providerIdentityCannotBeInferredFromAVersion() {
        let lume = Self.tuple(provider: .lume)
        let tart = Self.tuple(provider: .tart)
        #expect(lume != tart)
        #expect(lume.differences(from: tart) == [.runtimeProvider])
        var differentVersion = lume
        differentVersion.runtimeVersion = "0.5.4"
        #expect(lume.differences(from: differentVersion) == [.runtimeVersion])
    }

    @Test(arguments: CompatibilityField.allCases)
    func eachMissingFieldRemainsUnknown(_ field: CompatibilityField) throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.tuple())) as? [String: Any])
        #expect(json.removeValue(forKey: field.rawValue) != nil)
        let data = try JSONSerialization.data(withJSONObject: json)
        let observed = try JSONDecoder().decode(ObservedTuple.self, from: data)
        #expect(observed.unknownFields == [field])
        #expect(observed.exact == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CompatibilityTuple.self, from: data) }
    }

    @Test func legacyTartFieldDoesNotBecomeLumeEvidence() throws {
        let data = Data(#"{"tartVersion":"2.36.0"}"#.utf8)
        let observed = try JSONDecoder().decode(ObservedTuple.self, from: data)
        #expect(observed.runtimeProvider == nil)
        #expect(observed.runtimeVersion == nil)
        #expect(observed.exact == nil)
        #expect(observed.unknownFields == CompatibilityField.allCases)
        #expect(!String(decoding: try JSONEncoder().encode(observed), as: UTF8.self).contains("tartVersion"))
    }

    @Test func unknownProviderDoesNotDefaultToTheCandidate() {
        let data = Data(#"{"runtimeProvider":"syntheticOpaque"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ObservedTuple.self, from: data) }
    }

    @Test func capabilityNormalizationSurvivesConstructionAssignmentAndDecode() throws {
        let expected = Self.tuple(capabilities: ["a", "b"])
        var tuple = Self.tuple(capabilities: ["b", "a", "b"])
        #expect(tuple == expected)
        tuple.codexCLICapabilities = ["b", "a", "b"]
        #expect(tuple == expected)
        var observed = ObservedTuple(tuple)
        observed.codexCLICapabilities = ["b", "a", "b"]
        #expect(observed.exact == expected)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        object["codexCLICapabilities"] = ["b", "a", "b"]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(CompatibilityTuple.self, from: data) == expected)
        #expect(try JSONDecoder().decode(ObservedTuple.self, from: data).exact == expected)
    }

    @Test func tooManyCapabilitiesAreNotNormalizedIntoValidEvidence() throws {
        let excessive = Array(repeating: "same", count: 65)
        #expect(CompatibilityTuple.maximumCapabilities == 64)
        var tuple = Self.tuple(capabilities: excessive)
        #expect(tuple.codexCLICapabilities.count == 65)
        tuple.codexCLICapabilities = excessive
        #expect(tuple.codexCLICapabilities.count == 65)
        var observed = ObservedTuple(tuple)
        observed.codexCLICapabilities = excessive
        #expect(observed.codexCLICapabilities?.count == 65)
        let data = try JSONEncoder().encode(tuple)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CompatibilityTuple.self, from: data) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ObservedTuple.self, from: data) }
    }

    @Test func driftIncludesAllChangedIdentityComponents() {
        let first = Self.tuple()
        let second = CompatibilityTuple(
            hostMacOSVersion: SemanticVersion([27]), hostMacOSBuild: "26A1",
            codexDesktopVersion: "2", codexDesktopBuild: "2000", codexDesktopPath: "/Applications/Codex Beta.app",
            runtimeProtocolVersion: 2, runtimeProvider: .tart, runtimeVersion: "2.36.0",
            guestMacOSBuild: "26B1", xcodeBuild: "18A1", codexCLIVersion: "0.51.0",
            codexCLIPath: "/usr/local/bin/codex", codexCLIInstallations: 2, codexCLICapabilities: ["changed"],
            githubCLIVersion: "3", provisioningScriptVersion: "2"
        )
        #expect(first.differences(from: second) == CompatibilityField.allCases)
        #expect(first.differences(from: first).isEmpty)
    }
}
