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
        manifest.schemaVersion = SchemaVersion(SchemaVersion.current.rawValue + 1)!
        let data = try JSONEncoder().encode(manifest)
        #expect(throws: CompatibilityManifestError.unsupportedSchema(found: manifest.schemaVersion, supported: .current)) {
            try CompatibilityManifest.decode(from: data)
        }
        // The helper is a convenience, not the only gate: a caller reaching for Codable directly
        // must not get a manifest whose extra dimensions this build would ignore.
        #expect(throws: CompatibilityManifestError.unsupportedSchema(found: manifest.schemaVersion, supported: .current)) {
            try JSONDecoder().decode(CompatibilityManifest.self, from: data)
        }
    }

    @Test func damagedManifestResourcesReportSomethingTheUserCanDo() {
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest.decode(from: Data("not a manifest".utf8))
        }
        for error: CompatibilityManifestError in [.unreadableManifest, .malformedManifest] {
            #expect(!error.userMessage.isEmpty)
            #expect(error.recoveryActions.contains(.reinstallApp))
        }
        #expect(throws: Never.self) { try CompatibilityManifest.bundled() }
    }

    @Test func testedEntriesMustDeclareTheirCapabilities() throws {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        // Sorted, so the key this test removes is always followed by a comma: an encoder that
        // happened to put it last would leave the JSON valid and the test would prove nothing.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        let stale = json.replacingOccurrences(of: #""codexCLICapabilities":["remote-app-server"],"#, with: "")
        #expect(stale != json, "the capabilities key was removed")
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest.decode(from: Data(stale.utf8))
        }
    }

    @Test func rulesWithoutAnExplanationAreRejected() throws {
        let manifest = #"{"schemaVersion":1,"manifestVersion":1,"tested":[],"incompatibilities":[{"reason":"   "}]}"#
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest.decode(from: Data(manifest.utf8))
        }
        let cleared = try JSONDecoder().decode(CompatibilityManifest.KnownIncompatibility.self, from: Data(#"{"reason":"broken","recoveryActions":[]}"#.utf8))
        #expect(cleared.recoveryActions == defaults)
    }

    @Test func verificationTimestampsSurviveEncoding() throws {
        // Sub-second instants included on purpose: a real `Date()` has more precision than any
        // ISO 8601 form carries, and rounding it must land somewhere the encoder reproduces.
        let instants = [Date(), Date(timeIntervalSince1970: 1_800_000_000.123456)]
            + (0..<64).map { Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 0.176_666) }
        for instant in instants {
            let verification = CompatibilityManifest.Verification(verifiedAt: instant, hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
            let data = try JSONEncoder().encode(verification)
            #expect(try JSONDecoder().decode(CompatibilityManifest.Verification.self, from: data) == verification)
        }
    }

    @Test func capabilityOrderNeverDecidesWhetherARuleFires() {
        var manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        manifest.incompatibilities = [.init(codexCLICapabilities: ["apply-patch", "remote-app-server"], reason: "this capability pair deadlocks")]
        var observed = ObservedTuple(Fixtures.tuple())
        observed.codexCLICapabilities = ["remote-app-server", "apply-patch"]
        #expect(CompatibilityEvaluator.evaluate(observed: observed, manifest: manifest, history: []) == .incompatible(reason: "this capability pair deadlocks", recoveryActions: defaults))
    }

    @Test func negativeInstallationCountsAreNeverVerified() throws {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        let impossible = Fixtures.tuple(installations: -1)
        let history = [try ConnectionVerificationRecord(tuple: impossible, verifiedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: .userConfirmedWorkspaceOpened)]
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(impossible), manifest: manifest, history: history) == .needsValidation(.unknownFields([.codexCLIInstallations])))
    }

    @Test func decodedRecordsAreRevalidatedIncludingTheirEvidence() throws {
        let record = try ConnectionVerificationRecord(tuple: Fixtures.tuple(), verifiedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: .machineReadableStatus(source: "desktop-status"))
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let secret = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let poisonedTuple = json.replacingOccurrences(of: #""0.50.0""#, with: #""0.50.0 \#(secret)""#)
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIVersion)) {
            try JSONDecoder().decode(ConnectionVerificationRecord.self, from: Data(poisonedTuple.utf8))
        }
        let poisonedEvidence = json.replacingOccurrences(of: "desktop-status", with: "desktop-status \(secret)")
        #expect(throws: CompatibilityRecordError.implausibleEvidenceSource) {
            try JSONDecoder().decode(ConnectionVerificationRecord.self, from: Data(poisonedEvidence.utf8))
        }
        #expect(throws: CompatibilityRecordError.implausibleEvidenceSource) {
            try ConnectionVerificationRecord(tuple: Fixtures.tuple(), verifiedAt: Date(), evidence: .machineReadableStatus(source: "status\u{1B}[31m"))
        }
        #expect(!CompatibilityRecordError.implausibleEvidenceSource.userMessage.isEmpty)
    }

    @Test func fullLengthPathsAreRecordableButUnboundedOnesAreNot() throws {
        let deep = "/Users/dev/" + String(repeating: "nested/", count: 60) + "Codex.app"
        #expect(deep.unicodeScalars.count > ConnectionVerificationRecord.maximumObservationLength)
        var far = Fixtures.tuple()
        far.codexDesktopPath = deep
        far.codexCLIPath = deep + "/Contents/MacOS/codex"
        #expect(throws: Never.self) { try ConnectionVerificationRecord(tuple: far, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened) }
        var unbounded = Fixtures.tuple()
        unbounded.codexCLIPath = "/" + String(repeating: "a", count: ConnectionVerificationRecord.maximumPathLength)
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIPath)) {
            try ConnectionVerificationRecord(tuple: unbounded, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        var wordy = Fixtures.tuple()
        wordy.codexDesktopVersion = String(repeating: "1", count: ConnectionVerificationRecord.maximumObservationLength + 1)
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexDesktopVersion)) {
            try ConnectionVerificationRecord(tuple: wordy, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
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
        let error = CompatibilityManifestError.unsupportedSchema(found: SchemaVersion(9)!, supported: .current)
        #expect(error.recoveryActions.first == .reinstallApp)
        #expect(error.errorDescription == error.userMessage)
        let verification = CompatibilityManifest.Verification(verifiedAt: Date(timeIntervalSince1970: 1_800_000_000.25), hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
        let manifest = CompatibilityManifest(manifestVersion: 2, tested: [Fixtures.tested(verification: verification)])
        let data = try JSONEncoder().encode(manifest)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("2027-01-15T08:00:00Z"))
        #expect(try CompatibilityManifest.decode(from: data) == manifest)
        // A manifest authored with fractional seconds still reads, at the same precision.
        let fractional = json.replacingOccurrences(of: "2027-01-15T08:00:00Z", with: "2027-01-15T08:00:00.250Z")
        #expect(try CompatibilityManifest.decode(from: Data(fractional.utf8)) == manifest)
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
