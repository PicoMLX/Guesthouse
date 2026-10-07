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
        let result = try DiagnosticsExportBuilder.build(log: log, environmentIDs: [environment])
        let text = result.files.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!text.contains(marker))
        #expect(!text.contains("codexCLIPath") && !text.contains("codexDesktopPath"))
        #expect(text.contains(GuesthouseError.runtimeMissing.userMessage))
        #expect(text.contains(GuesthouseError.runtimeMissing.recoveryMessage))
    }
    @Test func environmentSelectionExcludesOtherActivityAndRetainsGlobalEvents() throws {
        let selected = EnvironmentID(), other = EnvironmentID()
        let selectedOperation = UUID(), otherOperation = UUID(), globalOperation = UUID()
        var log = DiagnosticLog(capacity: 3)
        for (id, operation) in [(other, UUID()), (selected, selectedOperation), (other, otherOperation)] {
            log.append(.init(operation: .startEnvironment, outcome: .succeeded, operationID: operation, environmentID: id))
        }
        log.append(.init(operation: .checkTools, outcome: .succeeded, operationID: globalOperation))
        let result = try DiagnosticsExportBuilder.build(log: log, environmentIDs: [selected])
        #expect(Set(result.files.keys) == ["manifest.json", "diagnostics.json", "log.txt", "excluded.txt"])
        let text = result.files.values.map { String(decoding: $0, as: UTF8.self).lowercased() }.joined()
        #expect(!text.contains(other.description.lowercased()) && !text.contains(otherOperation.uuidString.lowercased()))
        #expect(text.contains(selectedOperation.uuidString.lowercased()) && text.contains(globalOperation.uuidString.lowercased()))
        let manifest = try Self.object("manifest.json", in: result)
        #expect(manifest["schemaVersion"] as? Int == 1)
        #expect(manifest["recordCount"] as? Int == 2 && manifest["discardedCount"] as? Int == 1)
        #expect(Set(manifest.keys) == ["schemaVersion", "historyNotice", "exclusions", "selectedEnvironmentIDs", "eventEnvironmentIDs", "recordCount", "discardedCount"])
        let global = try DiagnosticsExportBuilder.build(log: log, environmentIDs: [])
        #expect(try Self.object("manifest.json", in: global)["recordCount"] as? Int == 1)
        let all = try DiagnosticsExportBuilder.build(log: log)
        #expect(try Self.object("manifest.json", in: all)["recordCount"] as? Int == 3)
    }
    @Test func localOmissionsAndStructuredSchemaRemainExplicit() throws {
        var log = DiagnosticLog(capacity: 1)
        let event = DiagnosticEvent(operation: .checkTools, outcome: .succeeded, operationID: UUID())
        log.append(event); log.append(event)
        let result = try DiagnosticsExportBuilder.build(log: log)
        let events = try Self.object("diagnostics.json", in: result)
        #expect(events["schemaVersion"] as? Int == 4 && events["discardedCount"] as? Int == 1)
        #expect((events["records"] as? [Any])?.count == 1)
    }
    @Test func invalidSelectionAndEncodingFailuresAreTyped() throws {
        let id = EnvironmentID()
        #expect(throws: DiagnosticsExportError.duplicateEnvironment) { try DiagnosticsExportBuilder.build(log: DiagnosticLog(), environmentIDs: [id, id]) }
        #expect(throws: DiagnosticsExportError.tooManyEnvironments) { try DiagnosticsExportBuilder.build(log: DiagnosticLog(), environmentIDs: [id, id, id]) }
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
