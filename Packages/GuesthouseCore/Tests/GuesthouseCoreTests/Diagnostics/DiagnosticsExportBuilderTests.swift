import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct DiagnosticsExportBuilderTests {
    let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"

    func export(lines: [String]) -> DiagnosticsExport {
        DiagnosticsExportBuilder.build(
            appVersion: "0.1", appBuild: "7",
            runtime: RuntimeVersionInfo(serviceVersion: "0.1", serviceBuild: "7", tart: .init(version: "2.36.0", verified: true)),
            compatibility: ObservedTuple(hostMacOSVersion: SemanticVersion("26.5.2"), tartVersion: "2.36.0"),
            environments: [DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))],
            logs: Redactor().redact(lines: lines),
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test func secretsAndAddressesNeverReachTheExport() throws {
        let export = export(lines: ["remote: token \(token) used", "guest at 192.168.64.7 answered", "ssh fe80::1c2a:3b4c:5d6e:7f80 pinged", "password: hunter2"])
        #expect(!export.logText.contains(token))
        #expect(export.logText.contains("[redacted:github-token]"))
        #expect(!export.logText.contains("192.168.64.7"))
        #expect(!export.logText.contains("fe80::1c2a"))
        #expect(!export.logText.contains("hunter2"))
        let manifest = String(decoding: try #require(export.files.first { $0.name == "manifest.json" }?.contents), as: UTF8.self)
        #expect(!manifest.contains(#/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/#))
        #expect(manifest.contains("\"hostMacOSVersion\" : \"26.5.2\""))
        #expect(manifest.contains("\"logLineCount\" : 4"))
        #expect(export.manifest.environmentIDs.count == 1)
        #expect(export.excludedText.contains("Network addresses"))
    }

    @Test func versionsAreAlsoScrubbedByTheAddressRule() {
        #expect(DiagnosticsExportBuilder.scrubAddresses("Tart 2.36.0 on macOS 26.5.2") == "Tart 2.36.0 on macOS 26.5.2", "three-component versions are not addresses")
        #expect(DiagnosticsExportBuilder.scrubAddresses("host 10.0.0.1:22") == "host [redacted:address]:22")
    }

    @Test func writesAFolderWithThreeFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Diagnostics-\(UUID().uuidString)")
        try DiagnosticsExportBuilder.write(export(lines: ["one"]), to: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["excluded.txt", "log.txt", "manifest.json"])
        #expect(try String(contentsOf: directory.appending(path: "log.txt"), encoding: .utf8) == "one\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DiagnosticsExport.Manifest.self, from: try Data(contentsOf: directory.appending(path: "manifest.json")))
        #expect(manifest.appVersion == "0.1")
        #expect(manifest.excludedCategories == DiagnosticsExportBuilder.excludedCategories)
    }
}
