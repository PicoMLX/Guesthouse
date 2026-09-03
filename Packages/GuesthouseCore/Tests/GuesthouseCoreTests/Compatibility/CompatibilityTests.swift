import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct SemanticVersionTests {
    @Test func parsesAndComparesNumerically() throws {
        let a = try #require(SemanticVersion("26.5.2"))
        let b = try #require(SemanticVersion("26.10"))
        let c = try #require(SemanticVersion("26.5"))
        #expect(a < b)
        #expect(c < a)
        #expect(SemanticVersion("26.5.0") == c)
        #expect(SemanticVersion("26.5.2-beta") == nil)
        #expect(SemanticVersion("-1") == nil)
        #expect(SemanticVersion("") == nil)
        #expect(a.description == "26.5.2")
    }

    @Test func rangeIsInclusiveAndOpenEnded() throws {
        let range = VersionRange(minimum: try #require(SemanticVersion("26.4")))
        #expect(range.contains(try #require(SemanticVersion("26.4"))))
        #expect(range.contains(try #require(SemanticVersion("27.0"))))
        #expect(!range.contains(try #require(SemanticVersion("26.3.9"))))
        let lower = try #require(SemanticVersion("26.2"))
        let upper = try #require(SemanticVersion("26.9"))
        let closed = VersionRange(minimum: lower, maximum: upper)
        #expect(closed.contains(try #require(SemanticVersion("26.9"))))
        #expect(!closed.contains(try #require(SemanticVersion("26.10"))))
    }

    @Test func encodedVersionsAlwaysDecode() throws {
        for version in [SemanticVersion([26, 4]), SemanticVersion([0]), SemanticVersion([1, 2, 3, 4])] {
            let data = try JSONEncoder().encode(version)
            #expect(try JSONDecoder().decode(SemanticVersion.self, from: data) == version)
        }
    }
}

@Suite struct CompatibilityEvaluatorTests {
    static func tuple(codexCLI: String = "0.50.0", host: String = "26.5.2", hostBuild: String = "25F84", path: String = "/opt/homebrew/bin/codex", installations: Int = 1, capabilities: [String] = ["remote-app-server"]) -> CompatibilityTuple {
        CompatibilityTuple(
            hostMacOSVersion: SemanticVersion(host)!, hostMacOSBuild: hostBuild,
            codexDesktopVersion: "1.2.3", codexDesktopBuild: "1234",
            runtimeProtocolVersion: 1, tartVersion: "2.36.0", guestMacOSBuild: "25F84",
            xcodeBuild: "17F113", codexCLIVersion: codexCLI, codexCLIPath: path,
            codexCLIInstallations: installations, codexCLICapabilities: capabilities,
            githubCLIVersion: "2.80.0", provisioningScriptVersion: "1"
        )
    }

    static func tested(codexCLI: String = "0.50.0", verification: CompatibilityManifest.Verification? = nil) -> CompatibilityManifest.TestedTuple {
        CompatibilityManifest.TestedTuple(
            hostMacOS: VersionRange(minimum: SemanticVersion("26.4")!),
            codexDesktopVersion: "1.2.3", codexDesktopBuild: "1234",
            runtimeProtocolVersion: 1, tartVersion: "2.36.0", guestMacOSBuild: "25F84",
            xcodeBuild: "17F113", codexCLIVersion: codexCLI, codexCLIPath: "/opt/homebrew/bin/codex",
            codexCLICapabilities: ["remote-app-server"], githubCLIVersion: "2.80.0",
            provisioningScriptVersion: "1", verification: verification
        )
    }

    let manifest = CompatibilityManifest(manifestVersion: 1, tested: [tested()])
    let day = Date(timeIntervalSince1970: 1_800_000_000)
    var record: ConnectionVerificationRecord { ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day, evidence: .userConfirmedWorkspaceOpened) }

    @Test func exactRecordedConnectionIsVerified() {
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [record])
        #expect(state == .verified(recordedAt: day))
        #expect(state.allowsHandoff)
    }

    @Test func anyChangedComponentSinceLastConnectionNeedsValidation() {
        let cases: [(CompatibilityTuple, [CompatibilityField])] = [
            (Self.tuple(codexCLI: "0.51.0"), [.codexCLIVersion]),
            (Self.tuple(hostBuild: "25F99"), [.hostMacOSBuild]),
            (Self.tuple(path: "/usr/local/bin/codex"), [.codexCLIPath]),
            (Self.tuple(capabilities: []), [.codexCLICapabilities]),
        ]
        for (drifted, expected) in cases {
            let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(drifted), manifest: manifest, history: [record])
            #expect(state == .needsValidation(.changedSinceLastVerified(expected)))
            #expect(!state.allowsHandoff)
        }
    }

    @Test func competingInstallationsNeedValidationEvenWithHistory() {
        let ambiguous = Self.tuple(installations: 2)
        let history = [ConnectionVerificationRecord(tuple: ambiguous, verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)]
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(ambiguous), manifest: manifest, history: history)
        #expect(state == .needsValidation(.competingInstallations(count: 2)))
    }

    @Test func unknownFieldIsNeverVerified() {
        var observed = ObservedTuple(Self.tuple())
        observed.codexDesktopBuild = nil
        observed.codexCLIPath = nil
        let state = CompatibilityEvaluator.evaluate(observed: observed, manifest: manifest, history: [record])
        #expect(state == .needsValidation(.unknownFields([.codexDesktopBuild, .codexCLIPath])))
    }

    @Test func knownIncompatibilityBlocksHandoffEvenWithHistory() {
        var manifest = manifest
        manifest.incompatibilities = [.init(codexCLIVersion: "0.50.0", reason: "0.50.0 cannot start the remote app-server")]
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [record])
        #expect(state == .incompatible(reason: "0.50.0 cannot start the remote app-server"))
    }

    @Test func incompatibilityRulesCoverHostAndProvisioningScript() {
        var manifest = manifest
        manifest.incompatibilities = [
            .init(hostMacOS: VersionRange(minimum: SemanticVersion("26.5")!, maximum: SemanticVersion("26.5.2")!), hostMacOSBuild: "25F84", reason: "host build breaks Screen Sharing tunnels"),
            .init(provisioningScriptVersion: "0", reason: "script 0 left password SSH enabled"),
        ]
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [record]) == .incompatible(reason: "host build breaks Screen Sharing tunnels"))
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple(host: "26.6", hostBuild: "25G10")), manifest: manifest, history: []) == .needsValidation(.neverConnected))
        var badScript = Self.tuple(host: "26.6", hostBuild: "25G10"); badScript.provisioningScriptVersion = "0"
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(badScript), manifest: manifest, history: []) == .incompatible(reason: "script 0 left password SSH enabled"))
    }

    @Test func incompatibilityRuleDoesNotFireOnUnknownField() {
        var manifest = manifest
        manifest.incompatibilities = [.init(hostMacOS: VersionRange(minimum: SemanticVersion("26")!), codexCLIVersion: "0.50.0", reason: "bad")]
        var observed = ObservedTuple(Self.tuple())
        observed.hostMacOSVersion = nil
        let state = CompatibilityEvaluator.evaluate(observed: observed, manifest: manifest, history: [])
        #expect(state == .needsValidation(.unknownFields([.hostMacOSVersion])))
    }

    @Test func testedButNeverConnectedNeedsValidation() {
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [])
        #expect(state == .needsValidation(.neverConnected))
    }

    @Test func manifestVerificationCountsOnlyForTheExactHost() {
        let verification = CompatibilityManifest.Verification(verifiedAt: day, hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
        let manifest = CompatibilityManifest(manifestVersion: 2, tested: [Self.tested(verification: verification)])
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: []) == .verified(recordedAt: day))
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple(host: "27.0", hostBuild: "26A1")), manifest: manifest, history: []) == .needsValidation(.verifiedOnDifferentHost))
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple(hostBuild: "25F99")), manifest: manifest, history: []) == .needsValidation(.verifiedOnDifferentHost))
    }

    @Test func untestedCombinationsNeedValidation() {
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple(codexCLI: "9.9.9")), manifest: manifest, history: []) == .needsValidation(.untestedCombination))
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple(host: "26.3")), manifest: manifest, history: []) == .needsValidation(.untestedCombination))
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple(path: "/usr/local/bin/codex")), manifest: manifest, history: []) == .needsValidation(.untestedCombination))
    }

    @Test func newestRecordWinsForRecordedAt() {
        let newer = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day.addingTimeInterval(3600), evidence: .machineReadableStatus(source: "test"))
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [record, newer])
        #expect(state == .verified(recordedAt: newer.verifiedAt))
    }

    @Test func capabilitiesCompareAsSets() {
        let a = Self.tuple(capabilities: ["b", "a"])
        let b = Self.tuple(capabilities: ["a", "b"])
        #expect(a == b)
        #expect(a.differences(from: b).isEmpty)
    }

    @Test func stateAndRecordsRoundTrip() throws {
        let record = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day, evidence: .machineReadableStatus(source: "desktop-status"))
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ConnectionVerificationRecord.self, from: data) == record)
        for state in [CompatibilityState.needsValidation(.changedSinceLastVerified([.tartVersion, .xcodeBuild])), .needsValidation(.competingInstallations(count: 3)), .needsValidation(.verifiedOnDifferentHost)] {
            let stateData = try JSONEncoder().encode(state)
            #expect(try JSONDecoder().decode(CompatibilityState.self, from: stateData) == state)
        }
    }
}

@Suite struct BundledManifestTests {
    @Test func bundledManifestDecodesAndIsEntirelyUnverified() throws {
        let manifest = try CompatibilityManifest.bundled()
        #expect(manifest.schemaVersion == .current)
        #expect(manifest.manifestVersion >= 1)
        #expect(!manifest.tested.isEmpty)
        #expect(manifest.tested.allSatisfy { !$0.isVerified })
        #expect(manifest.tested.first?.tartVersion == "2.36.0")
    }

    @Test func placeholdersNeverMatchAnObservation() throws {
        let manifest = try CompatibilityManifest.bundled()
        let observed = ObservedTuple(CompatibilityEvaluatorTests.tuple())
        let state = CompatibilityEvaluator.evaluate(observed: observed, manifest: manifest, history: [])
        #expect(state == .needsValidation(.untestedCombination))
    }
}
