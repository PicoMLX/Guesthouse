import Foundation
import GuesthouseCore
import Testing

struct ConnectionVerificationRecordTests {
    static func record(_ tuple: CompatibilityTuple = CompatibilityTupleTests.tuple()) throws -> ConnectionVerificationRecord {
        try ConnectionVerificationRecord(tuple: tuple, verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                         evidence: .userConfirmedWorkspaceOpened)
    }

    static func data(changing field: CompatibilityField, to value: Any) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record())) as? [String: Any])
        var tuple = try #require(object["tuple"] as? [String: Any])
        tuple[field.rawValue] = value
        object["tuple"] = tuple
        return try JSONSerialization.data(withJSONObject: [object])
    }

    @Test(arguments: VMProvider.allCases)
    func recordsRetainExactProviderIdentity(_ provider: VMProvider) throws {
        let record = try Self.record(CompatibilityTupleTests.tuple(provider: provider))
        #expect(record.schemaVersion.rawValue == 2)
        let data = try JSONEncoder().encode([record])
        #expect(try ConnectionVerificationRecord.decodeHistory(from: data) == [record])
    }

    @Test(arguments: [1, 3])
    func otherSchemasDoNotBecomeCurrentEvidence(_ version: Int) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.record())) as? [String: Any])
        object["schemaVersion"] = version
        let data = try JSONSerialization.data(withJSONObject: [object])
        #expect(throws: CompatibilityRecordError.unsupportedSchema(
            found: try #require(SchemaVersion(version)), supported: ConnectionVerificationRecord.currentSchema
        )) { try ConnectionVerificationRecord.decodeHistory(from: data) }
    }

    @Test(arguments: ["codex --version", "desktop-status", "syntheticOpaque"])
    func callersCannotInventMachineEvidence(_ source: String) throws {
        #expect(ConnectionVerificationRecord.supportedStatusInterfaces.isEmpty)
        let evidence = DesktopConnectionEvidence.machineReadableStatus(source: source)
        #expect(throws: CompatibilityRecordError.implausibleEvidenceSource) {
            try ConnectionVerificationRecord(tuple: CompatibilityTupleTests.tuple(), verifiedAt: .now, evidence: evidence)
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.record())) as? [String: Any])
        object["evidence"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence))
        let data = try JSONSerialization.data(withJSONObject: [object])
        #expect(throws: CompatibilityRecordError.implausibleEvidenceSource) {
            try ConnectionVerificationRecord.decodeHistory(from: data)
        }
    }

    @Test(arguments: [CompatibilityField.codexDesktopVersion, .codexDesktopBuild, .runtimeVersion,
                      .codexCLIVersion, .githubCLIVersion, .provisioningScriptVersion],
          ["", "1.2\nsyntheticOpaque", " 1.2", "1.2 ", "1.2/extra", "1.2\u{301}", String(repeating: "1", count: 257)])
    func versionFieldsUseBoundedIdentifierGrammar(_ field: CompatibilityField, _ value: String) throws {
        let data = try Self.data(changing: field, to: value)
        #expect(throws: CompatibilityRecordError.implausibleObservation(field)) {
            try ConnectionVerificationRecord.decodeHistory(from: data)
        }
    }

    @Test(arguments: [CompatibilityField.hostMacOSBuild, .guestMacOSBuild, .xcodeBuild])
    func buildIdentifiersCannotCarryCommandOutput(_ field: CompatibilityField) throws {
        let data = try Self.data(changing: field, to: "25A1\rsyntheticOpaque")
        #expect(throws: CompatibilityRecordError.implausibleObservation(field)) {
            try ConnectionVerificationRecord.decodeHistory(from: data)
        }
    }

    @Test func legitimateVersionSuffixesAndCapabilitiesArePreserved() throws {
        var tuple = CompatibilityTupleTests.tuple(capabilities: ["app_server:v2", "remote-app-server"])
        tuple.runtimeVersion = "0.5.3-rc.1+42"
        #expect(try Self.record(tuple).tuple == tuple)
    }

    @Test(arguments: ["/", "//", "////", "/bin/codex/", "codex", "../bin/codex", "/opt/../bin/codex", "/opt/./bin/codex", "/bin/codex\u{202E}", "/bin/codex\n",
                      "/" + String(repeating: "é", count: 512)])
    func invalidPathsFailWithoutReturningThePath(_ path: String) {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexCLIPath = path
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIPath)) { try Self.record(tuple) }
        tuple = CompatibilityTupleTests.tuple()
        tuple.codexDesktopPath = path
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexDesktopPath)) { try Self.record(tuple) }
    }

    @Test(arguments: ["abcdef0123456789abcdef0123456789abcdef0123", "b7255bd", String(repeating: "a", count: 64), "v1.2.3"])
    func provisioningIdentityMayBeAVersionOrCommit(_ identity: String) throws {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.provisioningScriptVersion = identity
        let record = try Self.record(tuple)
        #expect(record.tuple.provisioningScriptVersion == identity)
        #expect(try ConnectionVerificationRecord.decodeHistory(from: JSONEncoder().encode([record])) == [record])
    }

    @Test func privateIdentityPathsArePreservedNotRedacted() throws {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexDesktopPath = "/Users/De\u{301}veloper/My Apps/Codex.app"
        tuple.codexCLIPath = "/" + String(repeating: "subdir/", count: 100) + "codex"
        let record = try Self.record(tuple)
        #expect(record.tuple == tuple)
        #expect(try ConnectionVerificationRecord.decodeHistory(from: JSONEncoder().encode([record])) == [record])
    }

    @Test(arguments: [-1, 0, 2])
    func verificationRequiresExactlyOneCLI(_ count: Int) {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexCLIInstallations = count
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIInstallations)) { try Self.record(tuple) }
    }

    @Test(arguments: [-1, 0])
    func protocolIdentityMustBePositive(_ version: Int) {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.runtimeProtocolVersion = version
        #expect(throws: CompatibilityRecordError.implausibleObservation(.runtimeProtocolVersion)) { try Self.record(tuple) }
    }

    @Test(arguments: [[""], ["capability\nsyntheticOpaque"], [String(repeating: "a", count: 257)], Array(repeating: "same", count: 65)])
    func capabilitiesAreValidatedBeforeRecording(_ capabilities: [String]) {
        let tuple = CompatibilityTupleTests.tuple(capabilities: capabilities)
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLICapabilities)) { try Self.record(tuple) }
    }

    @Test(arguments: ["syntheticOpaque", "{}", "[{\"schemaVersion\":0}]", "[{\"schemaVersion\":2}]"])
    func malformedHistoryUsesFixedErrorWithoutDecoderDetails(_ text: String) {
        #expect(throws: CompatibilityRecordError.malformedHistory) {
            try ConnectionVerificationRecord.decodeHistory(from: Data(text.utf8))
        }
        let error = CompatibilityRecordError.malformedHistory
        #expect(!error.userMessage.contains(text))
        #expect(error.errorDescription == error.userMessage)
        #expect(error.recoveryActions == [.inspectState, .cancel])
    }

    @Test func rejectedValuesAndUnknownFieldsDoNotEnterErrorsOrRecords() throws {
        let data = try Self.data(changing: .codexCLIVersion, to: "1.0\nsyntheticOpaque")
        do { _ = try ConnectionVerificationRecord.decodeHistory(from: data); Issue.record("Expected rejection") }
        catch {
            #expect(error == .implausibleObservation(.codexCLIVersion))
            #expect(!error.userMessage.contains("syntheticOpaque"))
            #expect(error.recoveryActions.contains(.repair(.tools)))
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.record())) as? [String: Any])
        object["rawOutput"] = "syntheticOpaque"
        let history = try ConnectionVerificationRecord.decodeHistory(from: JSONSerialization.data(withJSONObject: [object]))
        #expect(!String(decoding: try JSONEncoder().encode(history), as: UTF8.self).contains("syntheticOpaque"))
    }
}
