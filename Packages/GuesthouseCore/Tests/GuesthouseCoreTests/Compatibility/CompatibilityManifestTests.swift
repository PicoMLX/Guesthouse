import Foundation
import GuesthouseCore
import Testing

struct CompatibilityManifestTests {
    static func manifest() throws -> CompatibilityManifest {
        try CompatibilityManifest(manifestVersion: 1, tested: [TestedCompatibilityTupleTests.entry()],
            incompatibilities: [.init(runtimeProvider: .tart, runtimeVersion: "2.36.0", reason: .incompatibleComponent(.runtimeVersion))])
    }

    @Test func currentManifestRoundTripsWithTypedReasons() throws {
        let manifest = try Self.manifest()
        #expect(try CompatibilityManifest.decode(from: JSONEncoder().encode(manifest)) == manifest)
        #expect(manifest.schemaVersion.rawValue == 2)
        #expect(manifest.incompatibilities.first?.reason.userMessage.contains("runtime version") == true)
    }

    @Test func bundledResourceDoesNotInventProviderEvidence() throws {
        let manifest = try CompatibilityManifest.bundled()
        #expect(manifest.tested.isEmpty)
        #expect(manifest.incompatibilities.isEmpty)
        #expect(manifest.schemaVersion == CompatibilityManifest.currentSchema)
    }

    @Test(arguments: [1, 3])
    func wrongSchemasFailThroughEveryEntryPoint(_ version: Int) throws {
        let schema = try #require(SchemaVersion(version))
        let expected = CompatibilityManifestError.unsupportedSchema(found: schema, supported: .init(2)!)
        #expect(throws: expected) { try CompatibilityManifest(schemaVersion: schema, manifestVersion: 1, tested: []) }
        let data = Data("{\"schemaVersion\":\(version),\"manifestVersion\":1,\"tested\":[],\"incompatibilities\":[]}".utf8)
        #expect(throws: expected) { try CompatibilityManifest.decode(from: data) }
        #expect(throws: expected) { try JSONDecoder().decode(CompatibilityManifest.self, from: data) }
    }

    @Test(arguments: [-1, 0])
    func revisionMustBePositive(_ revision: Int) {
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest(manifestVersion: revision, tested: [])
        }
    }

    @Test(arguments: ["syntheticOpaque", "{}", "{\"schemaVersion\":2}"])
    func malformedResourceUsesFixedRecovery(_ text: String) {
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest.decode(from: Data(text.utf8))
        }
        #expect(!CompatibilityManifestError.malformedManifest.userMessage.contains(text))
        #expect(CompatibilityManifestError.malformedManifest.recoveryActions == [.reinstallApp, .cancel])
        #expect(CompatibilityManifestError.unreadableManifest.errorDescription == CompatibilityManifestError.unreadableManifest.userMessage)
    }

    @Test func providerScopedRuleDoesNotBlockAnotherRuntime() {
        let rule = CompatibilityIncompatibility(runtimeProvider: .tart, runtimeVersion: "0.5.3", reason: .knownIncompatibleCombination)
        #expect(rule.applies(to: ObservedTuple(CompatibilityTupleTests.tuple(provider: .tart))))
        #expect(!rule.applies(to: ObservedTuple(CompatibilityTupleTests.tuple(provider: .lume))))
        var unknown = ObservedTuple(CompatibilityTupleTests.tuple(provider: .tart))
        unknown.runtimeProvider = nil
        #expect(!rule.applies(to: unknown))
    }

    @Test func rulesRetainIdentitySelectorsAndUnknownDoesNotMatch() {
        let tuple = CompatibilityTupleTests.tuple(capabilities: ["a", "b"])
        let rule = CompatibilityIncompatibility(
            hostMacOS: VersionRange(minimum: SemanticVersion([26]), maximum: SemanticVersion([27])),
            hostMacOSBuild: tuple.hostMacOSBuild, codexDesktopVersion: tuple.codexDesktopVersion,
            codexDesktopBuild: tuple.codexDesktopBuild, codexDesktopPath: tuple.codexDesktopPath,
            runtimeProtocolVersion: tuple.runtimeProtocolVersion, runtimeProvider: tuple.runtimeProvider,
            runtimeVersion: tuple.runtimeVersion, guestMacOSBuild: tuple.guestMacOSBuild, xcodeBuild: tuple.xcodeBuild,
            codexCLIVersion: tuple.codexCLIVersion, codexCLIPath: tuple.codexCLIPath, codexCLICapabilities: ["b", "a", "b"],
            githubCLIVersion: tuple.githubCLIVersion, provisioningScriptVersion: tuple.provisioningScriptVersion,
            reason: .incompatibleComponent(.codexCLIVersion)
        )
        var observed = ObservedTuple(tuple)
        #expect(rule.applies(to: observed))
        observed.codexCLICapabilities = ["b", "a", "b"]
        #expect(rule.applies(to: observed))
        observed.codexCLIPath = nil
        #expect(!rule.applies(to: observed))
        observed = ObservedTuple(tuple)
        observed.hostMacOSVersion = SemanticVersion([28])
        #expect(!rule.applies(to: observed))
        observed = ObservedTuple(tuple)
        observed.hostMacOSVersion = nil
        #expect(!rule.applies(to: observed))
        observed = ObservedTuple(tuple)
        observed.codexDesktopPath = "/Applications/Codex Beta.app"
        #expect(!rule.applies(to: observed))
    }

    @Test func recoveryCannotBeRemovedButTargetedRepairIsPreserved() throws {
        for actions: [RecoveryAction] in [[], [.cancel], [.repair(.runtime)]] {
            let rule = CompatibilityIncompatibility(reason: .knownIncompatibleCombination, recoveryActions: actions)
            let decoded = try JSONDecoder().decode(CompatibilityIncompatibility.self, from: JSONEncoder().encode(rule))
            #expect(decoded == rule)
            #expect(decoded.recoveryActions.contains(.openConsole))
            #expect(decoded.recoveryActions.contains(.exportWork))
            #expect(decoded.recoveryActions.contains(.cancel))
            #expect(decoded.recoveryActions.contains(actions.contains(.repair(.runtime)) ? .repair(.runtime) : .repair(.tools)))
            if actions.contains(.repair(.runtime)) { #expect(!decoded.recoveryActions.contains(.repair(.tools))) }
        }
    }

    @Test(arguments: ["", "syntheticOpaque", "knownIncompatibleCombination"])
    func rawStringReasonsCannotEnterTheManifest(_ rawReason: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.manifest())) as? [String: Any])
        object["incompatibilities"] = [["reason": rawReason]]
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest.decode(from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func excessiveRuleCapabilitiesCannotNormalizeIntoAValidDocument() throws {
        let rule = CompatibilityIncompatibility(codexCLICapabilities: Array(repeating: "same", count: 65), reason: .knownIncompatibleCombination)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CompatibilityIncompatibility.self, from: JSONEncoder().encode(rule))
        }
    }

    @Test func unknownTranscriptFieldsDoNotPropagate() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.manifest())) as? [String: Any])
        object["rawOutput"] = "syntheticOpaque"
        let decoded = try CompatibilityManifest.decode(from: JSONSerialization.data(withJSONObject: object))
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("syntheticOpaque"))
    }
}
