import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor
@Suite struct DiagnosticsTests {
    @Test func exportCarriesRedactedLinesEnvironmentIDsAndRuntimeInfoButNoAddresses() async throws {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let operation = OperationID()
        let raw = ["remote: token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab used", "guest 192.168.64.7 answered"]
        var events: [RuntimeEvent] = [.accepted(operation)]
        events += Redactor().redact(lines: raw).map { RuntimeEvent.log(operation, $0) }
        events.append(.completed(operation))
        let backend = ScriptedBackend(events: events, environments: [environment], status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, observed: ObservedTuple(tartVersion: "2.36.0")))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.runtimeInfo?.serviceVersion == "9.9")
        model.start(environment.id)
        for _ in 0..<400 where model.lastLogs[environment.id] == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.diagnosticsLines.count == 2)
        let export = model.diagnosticsExport()
        #expect(!export.logText.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(!export.logText.contains("192.168.64.7"))
        #expect(export.logText.contains("[redacted:github-token]"))
        #expect(export.manifest.environmentIDs == [environment.id])
        #expect(export.manifest.runtime?.serviceVersion == "9.9")
        #expect(export.manifest.compatibility.tartVersion == "2.36.0")
        let manifest = String(decoding: export.files[0].contents, as: UTF8.self)
        #expect(!manifest.contains("192.168"))
    }

    @Test func fileStampsHaveNoColons() {
        #expect(!DiagnosticsView.stamp(Date(timeIntervalSince1970: 1_800_000_000)).contains(":"))
    }

    @Test func theWriterCreatesAFolderWithThreeFiles() throws {
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: nil, compatibility: ObservedTuple(), environments: [], logs: [])
        let directory = FileManager.default.temporaryDirectory.appending(path: "Diagnostics-\(UUID().uuidString)")
        try DiagnosticsExportWriter.write(export, to: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == [DiagnosticsExport.excludedFileName, DiagnosticsExport.logFileName, DiagnosticsExport.manifestFileName])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
    }
}
