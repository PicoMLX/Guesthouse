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
}

@Suite struct CompatibilityEvaluatorTests {
    static func tuple(codexCLI: String = "0.50.0", host: String = "26.5.2") -> CompatibilityTuple {
        CompatibilityTuple(
            hostMacOSVersion: SemanticVersion(host)!,
            codexDesktopVersion: "1.2.3", codexDesktopBuild: "1234",
            runtimeProtocolVersion: 1, tartVersion: "2.36.0", guestMacOSBuild: "25F84",
            xcodeBuild: "17F113", codexCLIVersion: codexCLI, githubCLIVersion: "2.80.0",
            provisioningScriptVersion: "1"
        )
    }

    static func tested(codexCLI: String = "0.50.0", verifiedAt: Date? = nil) -> CompatibilityManifest.TestedTuple {
        CompatibilityManifest.TestedTuple(
            hostMacOS: VersionRange(minimum: SemanticVersion("26.4")!),
            codexDesktopVersion: "1.2.3", codexDesktopBuild: "1234",
            runtimeProtocolVersion: 1, tartVersion: "2.36.0", guestMacOSBuild: "25F84",
            xcodeBuild: "17F113", codexCLIVersion: codexCLI, githubCLIVersion: "2.80.0",
            provisioningScriptVersion: "1", verifiedAt: verifiedAt
        )
    }

    let manifest = CompatibilityManifest(manifestVersion: 1, tested: [tested()])
    let day = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func exactRecordedConnectionIsVerified() {
        let record = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [record])
        #expect(state == .verified(recordedAt: day))
        #expect(state.allowsHandoff)
    }

    @Test func changedComponentSinceLastConnectionNeedsValidation() {
        let record = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)
        let drifted = ObservedTuple(Self.tuple(codexCLI: "0.51.0"))
        let state = CompatibilityEvaluator.evaluate(observed: drifted, manifest: manifest, history: [record])
        #expect(state == .needsValidation(.changedSinceLastVerified([.codexCLIVersion])))
        #expect(!state.allowsHandoff)
    }

    @Test func unknownFieldIsNeverVerified() {
        var observed = ObservedTuple(Self.tuple())
        observed.codexDesktopBuild = nil
        let record = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)
        let state = CompatibilityEvaluator.evaluate(observed: observed, manifest: manifest, history: [record])
        #expect(state == .needsValidation(.unknownFields([.codexDesktopBuild])))
    }

    @Test func knownIncompatibilityBlocksHandoffEvenWithHistory() {
        var manifest = manifest
        manifest.incompatibilities = [.init(codexCLIVersion: "0.50.0", reason: "0.50.0 cannot start the remote app-server")]
        let record = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [record])
        #expect(state == .incompatible(reason: "0.50.0 cannot start the remote app-server"))
    }

    @Test func incompatibilityRuleDoesNotFireOnUnknownField() {
        var manifest = manifest
        manifest.incompatibilities = [.init(codexCLIVersion: "0.50.0", reason: "bad")]
        var observed = ObservedTuple(Self.tuple())
        observed.codexCLIVersion = nil
        let state = CompatibilityEvaluator.evaluate(observed: observed, manifest: manifest, history: [])
        #expect(state == .needsValidation(.unknownFields([.codexCLIVersion])))
    }

    @Test func testedButNeverConnectedNeedsValidation() {
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [])
        #expect(state == .needsValidation(.neverConnected))
    }

    @Test func manifestVerifiedTupleCountsWithoutLocalHistory() {
        let manifest = CompatibilityManifest(manifestVersion: 2, tested: [Self.tested(verifiedAt: day)])
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [])
        #expect(state == .verified(recordedAt: day))
    }

    @Test func untestedCombinationNeedsValidation() {
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple(codexCLI: "9.9.9")), manifest: manifest, history: [])
        #expect(state == .needsValidation(.untestedCombination))
    }

    @Test func hostVersionOutsideRangeIsUntested() {
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple(host: "26.3")), manifest: manifest, history: [])
        #expect(state == .needsValidation(.untestedCombination))
    }

    @Test func newestRecordWinsForRecordedAt() {
        let older = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)
        let newer = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day.addingTimeInterval(3600), evidence: .machineReadableStatus(source: "test"))
        let state = CompatibilityEvaluator.evaluate(observed: ObservedTuple(Self.tuple()), manifest: manifest, history: [older, newer])
        #expect(state == .verified(recordedAt: newer.verifiedAt))
    }

    @Test func stateAndRecordsRoundTrip() throws {
        let record = ConnectionVerificationRecord(tuple: Self.tuple(), verifiedAt: day, evidence: .machineReadableStatus(source: "desktop-status"))
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ConnectionVerificationRecord.self, from: data) == record)
        let state = CompatibilityState.needsValidation(.changedSinceLastVerified([.tartVersion, .xcodeBuild]))
        let stateData = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(CompatibilityState.self, from: stateData) == state)
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
