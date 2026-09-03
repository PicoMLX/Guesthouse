import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct CompatibilityHardeningTests {
    typealias Fixtures = CompatibilityEvaluatorTests
    let defaults = CompatibilityManifest.KnownIncompatibility.defaultRecoveryActions

    @Test func decodedCapabilitiesAreNormalized() throws {
        let tuple = Fixtures.tuple(capabilities: ["b", "a"])
        let encoded = String(decoding: try JSONEncoder().encode(tuple), as: UTF8.self)
        #expect(encoded.contains(#"["a","b"]"#))
        let shuffled = encoded.replacingOccurrences(of: #"["a","b"]"#, with: #"["b","a","b"]"#)
        let decoded = try JSONDecoder().decode(CompatibilityTuple.self, from: Data(shuffled.utf8))
        #expect(decoded == tuple)
        #expect(decoded.codexCLICapabilities == ["a", "b"])
        let observed = try JSONDecoder().decode(ObservedTuple.self, from: Data(shuffled.utf8))
        #expect(observed.exact == tuple)
    }

    @Test func newerManifestSchemasAreRejected() throws {
        var manifest = CompatibilityManifest(manifestVersion: 1, tested: [])
        manifest.schemaVersion = SchemaVersion(SchemaVersion.current.rawValue + 1)
        let data = try JSONEncoder().encode(manifest)
        #expect(throws: CompatibilityManifestError.unsupportedSchema(found: manifest.schemaVersion, supported: .current)) {
            try CompatibilityManifest.decode(from: data)
        }
    }

    @Test func invertedRangesAreRejectedWhenDecoding() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionRange.self, from: Data(#"{"minimum":"26.5","maximum":"26.4"}"#.utf8))
        }
    }

    @Test func rulesCanTargetCLIIdentityCapabilitiesAndDesktopBundle() {
        var manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        manifest.incompatibilities = [
            .init(codexCLIVersion: "0.50.0", codexCLIPath: "/usr/local/bin/codex", reason: "bottle is broken", recoveryActions: [.repair(.tools), .cancel]),
            .init(codexCLICapabilities: ["legacy-transport"], reason: "legacy transport"),
            .init(codexDesktopPath: "/Applications/Codex Beta.app", reason: "beta desktop"),
        ]
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Fixtures.tuple()), manifest: manifest, history: []) == .needsValidation(.neverConnected))
        let broken = ObservedTuple(Fixtures.tuple(path: "/usr/local/bin/codex"))
        #expect(CompatibilityEvaluator.evaluate(observed: broken, manifest: manifest, history: []) == .incompatible(reason: "bottle is broken", recoveryActions: [.repair(.tools), .cancel]))
        let legacy = ObservedTuple(Fixtures.tuple(capabilities: ["legacy-transport"]))
        #expect(CompatibilityEvaluator.evaluate(observed: legacy, manifest: manifest, history: []) == .incompatible(reason: "legacy transport", recoveryActions: defaults))
        var beta = Fixtures.tuple()
        beta.codexDesktopPath = "/Applications/Codex Beta.app"
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(beta), manifest: manifest, history: []) == .incompatible(reason: "beta desktop", recoveryActions: defaults))
    }

    @Test func implausibleObservationsAreNeverRecorded() {
        var poisoned = Fixtures.tuple()
        poisoned.codexCLIVersion = "0.50.0 ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIVersion)) {
            try ConnectionVerificationRecord(tuple: poisoned, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        var control = Fixtures.tuple()
        control.guestMacOSBuild = "25F84\u{1B}[31m"
        #expect(throws: CompatibilityRecordError.implausibleObservation(.guestMacOSBuild)) {
            try ConnectionVerificationRecord(tuple: control, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        var capability = Fixtures.tuple(capabilities: [String(repeating: "x", count: 300)])
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLICapabilities)) {
            try ConnectionVerificationRecord(tuple: capability, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        capability.codexCLICapabilities = ["remote-app-server"]
        #expect(throws: Never.self) { try ConnectionVerificationRecord(tuple: capability, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened) }
        let error = CompatibilityRecordError.implausibleObservation(.codexCLIVersion)
        #expect(!error.userMessage.isEmpty && !error.recoveryActions.isEmpty)
    }

    @Test func manifestErrorsAreActionableAndVerifiedManifestsRoundTrip() throws {
        let error = CompatibilityManifestError.unsupportedSchema(found: SchemaVersion(9), supported: .current)
        #expect(error.recoveryActions.first == .reinstallApp)
        #expect(error.errorDescription == error.userMessage)
        let verification = CompatibilityManifest.Verification(verifiedAt: Date(timeIntervalSince1970: 1_800_000_000.25), hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
        let manifest = CompatibilityManifest(manifestVersion: 2, tested: [Fixtures.tested(verification: verification)])
        let data = try JSONEncoder().encode(manifest)
        #expect(String(decoding: data, as: UTF8.self).contains("2027-01-15T08:00:00.250Z"))
        #expect(try CompatibilityManifest.decode(from: data) == manifest)
    }

    @Test func aMissingCLIIsAMissingPrerequisiteNotACompetingInstallation() {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        var none = ObservedTuple(Fixtures.tuple(installations: 0))
        #expect(CompatibilityEvaluator.evaluate(observed: none, manifest: manifest, history: []) == .needsValidation(.codexCLIMissing))
        none.codexCLIVersion = nil
        none.codexCLIPath = nil
        #expect(CompatibilityEvaluator.evaluate(observed: none, manifest: manifest, history: []) == .needsValidation(.codexCLIMissing))
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Fixtures.tuple(installations: 2)), manifest: manifest, history: []) == .needsValidation(.competingInstallations(count: 2)))
    }

    @Test func replacedDesktopBundleIsDrift() {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try! ConnectionVerificationRecord(tuple: Fixtures.tuple(), verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)
        var moved = Fixtures.tuple()
        moved.codexDesktopPath = "/Users/dev/Applications/Codex.app"
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(moved), manifest: manifest, history: [record]) == .needsValidation(.changedSinceLastVerified([.codexDesktopPath])))
        var unknownBundle = ObservedTuple(Fixtures.tuple())
        unknownBundle.codexDesktopPath = nil
        #expect(CompatibilityEvaluator.evaluate(observed: unknownBundle, manifest: manifest, history: [record]) == .needsValidation(.unknownFields([.codexDesktopPath])))
    }
}
