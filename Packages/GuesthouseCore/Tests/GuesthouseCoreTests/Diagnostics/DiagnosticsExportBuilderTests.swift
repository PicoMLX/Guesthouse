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
            environments: [], logs: [], launchFailure: .init(error)
        )
        let failure = export.manifest.launchFailure
        #expect(failure?.message == error.userMessage)
        #expect(failure?.recoveryActions.isEmpty == false, "the export names what the user was offered")
        #expect(String(decoding: DiagnosticsExportBuilder.encode(export.manifest), as: UTF8.self).contains("launchFailure"))
    }

    @Test func theOperationFailureIsInTheManifestBesideTheLaunchFailure() {
        let error = GuesthouseError.guestNotReachable(EnvironmentID())
        let export = DiagnosticsExportBuilder.build(
            appVersion: "1", appBuild: "1", runtime: nil, compatibility: ObservedTuple(),
            environments: [], logs: [], operationFailure: .init(error)
        )
        #expect(export.manifest.operationFailure?.message == error.userMessage)
        #expect(export.manifest.operationFailure?.recoveryActions.isEmpty == false)
        #expect(export.manifest.launchFailure == nil)
    }

    @Test func macAddressesAreScrubbed() {
        #expect(DiagnosticsExportBuilder.scrub("guest nic 52:54:00:12:34:56 up") == "guest nic [redacted:address] up")
        #expect(DiagnosticsExportBuilder.scrub("started at 12:30:45 sharp") == "started at 12:30:45 sharp", "a clock time is not an address")
    }

    @Test func aMACAddressInsideAMachineGeneratedIdentifierIsScrubbed() {
        #expect(DiagnosticsExportBuilder.scrub("nic_52:54:00:12:34:56_state up") == "nic_[redacted:address]_state up")
        #expect(DiagnosticsExportBuilder.scrub("52:54:00:12:34:56_link=down") == "[redacted:address]_link=down")
        #expect(
            DiagnosticsExportBuilder.scrub("prefix 2001:0db8:0000:0000:0000:ff00:0042:8329 up") == "prefix [redacted:address] up",
            "a longer colon run is still taken whole rather than cut into six pairs"
        )
    }

    @Test func multiWordAccountNamesAreScrubbedWhole() {
        #expect(DiagnosticsExportBuilder.scrub("Signed in as Alice Smith") == "Signed in as [redacted:account]")
        #expect(DiagnosticsExportBuilder.scrub("{\"user\":\"Alice Smith\"}") == "{\"user\":\"[redacted:account]\"}")
        // A label followed by a space is prose, so the marker replaces the quotes with it;
        // the quoting is only kept where a parser depends on it, in the structured form above.
        #expect(DiagnosticsExportBuilder.scrub("account: 'Alice Smith'") == "account: [redacted:account]")
        #expect(DiagnosticsExportBuilder.scrub("Signed in as \"Alice Smith\"") == "Signed in as [redacted:account]")
        // The value still ends where it stops looking like a name, so the qualifier a CLI
        // prints after the account survives for the reader of the bundle.
        #expect(DiagnosticsExportBuilder.scrub("user: octocat (admin)") == "user: [redacted:account] (admin)")
        #expect(DiagnosticsExportBuilder.scrub("Logged in to github.com as octocat with a keyring token") == "Logged in to github.com as [redacted:account] with a keyring token")
    }

    @Test func anIPv6AddressFollowedByALabelDelimiterIsScrubbed() {
        #expect(DiagnosticsExportBuilder.scrub("peer 2001:db8::1: connection failed") == "peer [redacted:address]: connection failed")
        #expect(DiagnosticsExportBuilder.scrub("prefix 2001:db8:: assigned") == "prefix [redacted:address] assigned", "a prefix is itself an address")
    }

    @Test func addressesInsideMachineGeneratedIdentifiersAreScrubbed() {
        #expect(DiagnosticsExportBuilder.scrub("peer_192.168.64.7 timed out") == "peer_[redacted:address] timed out")
        #expect(DiagnosticsExportBuilder.scrub("192.168.64.7_status=down") == "[redacted:address]_status=down")
        #expect(DiagnosticsExportBuilder.scrub("build 1.2.3.4.5 shipped") == "build 1.2.3.4.5 shipped", "a five-part version is not an address")
    }

    @Test func localUserAtHostIdentifiersAreScrubbed() {
        #expect(DiagnosticsExportBuilder.scrub("ssh alice@guesthouse failed") == "ssh [redacted:account] failed")
        #expect(DiagnosticsExportBuilder.scrub("ssh alice@192.168.64.7 failed") == "ssh [redacted:account] failed")
    }

    @Test func theAccountInFrontOfABracketedIPv6HostIsScrubbed() {
        // SSH brackets an IPv6 host, and the address pass keeps those brackets around its
        // marker, so the account is met as `alice@[[redacted:address]]`.
        #expect(DiagnosticsExportBuilder.scrub("ssh alice@[2001:db8::1] failed") == "ssh [redacted:account] failed")
        #expect(DiagnosticsExportBuilder.scrub("ssh alice@[192.168.64.7] failed") == "ssh [redacted:account] failed")
    }

    @Test func anIPv6AddressInsideAMachineGeneratedIdentifierIsScrubbed() {
        #expect(DiagnosticsExportBuilder.scrub("peer_2001:db8::1_status down") == "peer_[redacted:address]_status down")
        #expect(DiagnosticsExportBuilder.scrub("fe80::1_state=up") == "[redacted:address]_state=up")
        #expect(DiagnosticsExportBuilder.scrub("foo_::bar failed to build") == "foo_::bar failed to build", "an underscore does not make a qualified name an address")
    }

    @Test func theRuntimeProblemKeepsItsOwnCase() throws {
        let info = RuntimeVersionInfo(
            serviceVersion: "1", serviceBuild: "1",
            tart: .init(version: nil, verified: false, problem: .runtimeVerificationFailed(check: .signature))
        )
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: info, compatibility: ObservedTuple(), environments: [], logs: [])
        #expect(export.manifest.runtime?.tart?.problem == .runtimeVerificationFailed(check: .signature))
    }

    @Test func theRuntimeProblemsFreeTextIsScrubbedInPlace() throws {
        let info = RuntimeVersionInfo(
            serviceVersion: "1", serviceBuild: "1",
            tart: .init(version: nil, verified: false, problem: .runtimeStorageUnavailable(reason: SanitizedText("/Users/alice/Library/Application Support is full"), problem: .unwritable))
        )
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: info, compatibility: ObservedTuple(), environments: [], logs: [])
        let problem = try #require(export.manifest.runtime?.tart?.problem)
        guard case .runtimeStorageUnavailable(let reason, let kind) = problem else {
            Issue.record("the storage problem lost its case")
            return
        }
        #expect(!reason.value.contains("alice"))
        #expect(kind == .unwritable)
    }

    @Test func everyCompatibilityStringIsScrubbed() {
        let observed = ObservedTuple(
            xcodeBuild: "reported by 192.168.64.7",
            githubCLIVersion: "2.62.0 as alice@example.com",
            provisioningScriptVersion: "run from /Users/alice/scripts"
        )
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: nil, compatibility: observed, environments: [], logs: [])
        let manifest = String(decoding: DiagnosticsExportBuilder.encode(export.manifest), as: UTF8.self)
        #expect(!manifest.contains("192.168.64.7"))
        #expect(!manifest.contains("alice"))
        #expect(export.manifest.compatibility.xcodeBuild == "reported by [redacted:address]")
    }
}
