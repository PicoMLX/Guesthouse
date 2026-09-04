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

    @Test func compressedAndMappedIPv6AddressesAreScrubbedButTimesAreNot() {
        for address in ["::1", "2001:db8::1", "fe80::1c2a:3b4c:5d6e:7f80", "::ffff:192.0.2.1", "2001:0db8:85a3:0000:0000:8a2e:0370:7334"] {
            let scrubbed = DiagnosticsExportBuilder.scrubAddresses("guest at \(address) answered")
            #expect(scrubbed == "guest at [redacted:address] answered", "\(address)")
        }
        #expect(DiagnosticsExportBuilder.scrubAddresses("12:30:45.123 started") == "12:30:45.123 started")
        #expect(DiagnosticsExportBuilder.scrubAddresses("ratio 1:2") == "ratio 1:2")
    }

    @Test func punctuationVersionsAndHomePathsAreHandled() {
        #expect(DiagnosticsExportBuilder.scrub("guest at 2001:db8::1.") == "guest at [redacted:address].")
        #expect(DiagnosticsExportBuilder.scrub("tool 1.2.3.456 built") == "tool 1.2.3.456 built", "a version is not an address")
        #expect(DiagnosticsExportBuilder.scrub("guest at 192.168.64.7 answered") == "guest at [redacted:address] answered")
        #expect(DiagnosticsExportBuilder.scrub("/Users/alice/Library/Logs") == "/Users/[redacted:account]/Library/Logs")
    }

    @Test func aCredentialContinuedOnTheNextLineIsRedacted() {
        let redactor = Redactor()
        let lines = redactor.redact(lines: ["password:", "  hunter2", "next line"])
        let scrubbed = DiagnosticsExportBuilder.scrubbedStream(lines)
        // The redactor's own streaming state now catches this first, so the marker may be its
        // `secret` rather than the export's `credential`. What matters is that the value is gone.
        #expect(scrubbed[1].contains("[redacted:"))
        #expect(!scrubbed[1].contains("hunter2"))
        #expect(scrubbed[2] == "next line")
    }

    @Test func compatibilityPathsAreScrubbedInTheManifest() {
        let observed = ObservedTuple(codexDesktopPath: "/Users/alice/Applications/Codex.app", codexCLIPath: "/Users/alice/.codex/bin/codex")
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: nil, compatibility: observed, environments: [], logs: [])
        let manifest = String(decoding: DiagnosticsExportBuilder.encode(export.manifest), as: UTF8.self)
        #expect(!manifest.contains("alice"))
        #expect(manifest.contains("[redacted:account]"))
    }

    @Test func accountIdentifiersAreScrubbed() {
        #expect(DiagnosticsExportBuilder.scrub("Signed in as alice@example.com") == "Signed in as [redacted:account]")
        #expect(DiagnosticsExportBuilder.scrub("Logged in to github.com as octocat") == "Logged in to github.com as [redacted:account]")
        #expect(DiagnosticsExportBuilder.scrub("user: octocat (admin)") == "user: [redacted:account] (admin)")
        #expect(DiagnosticsExportBuilder.scrub("Contact ops@example.org for help") == "Contact [redacted:account] for help")
        #expect(DiagnosticsExportBuilder.scrub("Xcode 26.6 selected") == "Xcode 26.6 selected")
    }
    @Test func qualifiedNamesAreNotMistakenForAddresses() {
        #expect(DiagnosticsExportBuilder.scrub("foo::bar failed to build") == "foo::bar failed to build")
        #expect(DiagnosticsExportBuilder.scrub("std::vector<int>::size") == "std::vector<int>::size")
        #expect(DiagnosticsExportBuilder.scrub("guest at 2001:db8::1 answered") == "guest at [redacted:address] answered")
    }

    @Test func equalsDelimitedAndQuotedAccountFieldsAreScrubbed() {
        #expect(DiagnosticsExportBuilder.scrub("user=octocat") == "user=[redacted:account]")
        #expect(DiagnosticsExportBuilder.scrub("account = alice") == "account = [redacted:account]")
        #expect(DiagnosticsExportBuilder.scrub("{\"user\":\"alice\"}") == "{\"user\":\"[redacted:account]\"}")
        #expect(DiagnosticsExportBuilder.scrub("owner=alice@example.com") == "owner=[redacted:account]")
        #expect(DiagnosticsExportBuilder.scrub("timeout=30") == "timeout=30", "only account labels are scrubbed")
    }

    @Test func theLaunchFailureTheUserIsReportingIsInTheManifest() {
        let error = GuesthouseError.runtimeMissing
        let export = DiagnosticsExportBuilder.build(
            appVersion: "1", appBuild: "1", runtime: nil, compatibility: ObservedTuple(),
            environments: [], logs: [], launchError: error
        )
        let failure = export.manifest.launchFailure
        #expect(failure?.message == error.userMessage)
        #expect(failure?.recoveryActions.isEmpty == false, "the export names what the user was offered")
        #expect(String(decoding: DiagnosticsExportBuilder.encode(export.manifest), as: UTF8.self).contains("launchFailure"))
    }
}
