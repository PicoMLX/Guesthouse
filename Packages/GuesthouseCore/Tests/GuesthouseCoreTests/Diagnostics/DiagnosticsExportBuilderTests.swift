import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct DiagnosticsExportBuilderTests {
    @Test func rawAttachmentsAndPrivateStatusFieldsCannotReachExport() throws {
        let marker = "synthetic-private-token", environment = EnvironmentID(), operation = UUID()
        let event = DiagnosticEvent(operation: .startEnvironment, outcome: .operationFailed(.runtimeMissing), operationID: operation, environmentID: environment)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        for key in ["stdout", "stderr", "message", "underlyingError", "password"] { object[key] = marker }
        let typed = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object))
        var log = DiagnosticLog(); log.append(typed)
        let status = EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready, observed: .init(
            codexDesktopVersion: marker, codexDesktopPath: "/Users/\(marker)/Codex.app", runtimeVersion: "192.0.2.1",
            xcodeBuild: "17F113", codexCLIVersion: "1.2.3", codexCLIPath: "/opt/\(marker)/codex", codexCLICapabilities: [marker]))
        let result = try DiagnosticsExportBuilder.build(log: log, appVersion: marker, appBuild: "fe80::1", environments: [status])
        let text = result.files.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!text.contains(marker) && !text.contains("192.0.2.1") && !text.contains("fe80::1"))
        #expect(!text.contains("codexCLIPath") && !text.contains("codexDesktopPath"))
        let manifest = try Self.object("manifest.json", in: result)
        let metadata = try #require(manifest["environments"] as? [[String: Any]])
        #expect(metadata[0]["runtimeVersion"] == nil) // Omitted, not an address transformed into numeric components.
        #expect(text.contains(GuesthouseError.runtimeMissing.userMessage))
        #expect(text.contains(GuesthouseError.runtimeMissing.recoveryMessage))
    }
    @Test func manifestUsesKnownVersionComponentsAndNoReadinessClaims() throws {
        let id = EnvironmentID()
        let status = EnvironmentStatus(environmentID: id, vm: .running, readiness: .ready,
            observed: .init(hostMacOSVersion: SemanticVersion("26.6"), guestMacOSBuild: "26A123a", xcodeBuild: "17F113", codexCLIVersion: "0.42.1"), runtimeInstanceID: UUID())
        let result = try DiagnosticsExportBuilder.build(log: DiagnosticLog(), appVersion: "1.2.0", appBuild: "42",
            runtime: .init(serviceVersion: "1.2", serviceBuild: "43", runtime: .init(provider: .lume, version: "0.5.3", verified: false, problem: .runtimeIncompatible)), environments: [status])
        #expect(Set(result.files.keys) == ["manifest.json", "diagnostics.json", "log.txt", "excluded.txt"])
        let manifest = try Self.object("manifest.json", in: result)
        #expect(manifest["appVersion"] as? [Int] == [1, 2] && manifest["appBuild"] as? Int == 42)
        #expect(manifest["reportedRuntimeVersion"] as? [Int] == [0, 5, 3] && manifest["verified"] == nil)
        let environments = try #require(manifest["environments"] as? [[String: Any]])
        #expect(environments[0]["xcodeBuild"] as? String == "17F113")
        #expect(environments[0]["runtimeInstanceID"] == nil && environments[0]["readiness"] == nil)
        #expect(String(decoding: try #require(result.files["log.txt"]), as: UTF8.self).contains(DiagnosticsExportBuilder.historyNotice))
    }
    @Test func localOmissionsAndStructuredSchemaRemainExplicit() throws {
        var log = DiagnosticLog(capacity: 1)
        let event = DiagnosticEvent(operation: .checkTools, outcome: .succeeded, operationID: UUID())
        log.append(event); log.append(event)
        let result = try DiagnosticsExportBuilder.build(log: log)
        let events = try Self.object("diagnostics.json", in: result)
        #expect(events["schemaVersion"] as? Int == 3 && events["discardedCount"] as? Int == 1)
        #expect((events["records"] as? [Any])?.count == 1)
    }
    @Test func invalidSelectionAndEncodingFailuresAreTyped() throws {
        let status = EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped, readiness: .checking)
        #expect(throws: DiagnosticsExportError.duplicateEnvironment) { try DiagnosticsExportBuilder.build(log: DiagnosticLog(), environments: [status, status]) }
        #expect(throws: DiagnosticsExportError.tooManyEnvironments) { try DiagnosticsExportBuilder.build(log: DiagnosticLog(), environments: [status, status, status]) }
        var log = DiagnosticLog()
        log.append(.init(operation: .checkTools, outcome: .succeeded, operationID: UUID()), recordedAt: Date(timeIntervalSince1970: .infinity))
        #expect(throws: DiagnosticsExportError.encodingFailed) { try DiagnosticsExportBuilder.build(log: log) }
        #expect(!DiagnosticsExportError.encodingFailed.userMessage.isEmpty && !DiagnosticsExportError.encodingFailed.recoveryActions.isEmpty)
    }
    private static func object(_ name: String, in export: DiagnosticsExport) throws -> [String: Any] {
        let data = try #require(export.files[name])
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

}
