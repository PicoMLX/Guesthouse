import Foundation
import GuesthouseCore
import Testing

struct CompatibilityEvaluatorTests {
    static func evaluate(_ observed: ObservedTuple = ObservedTuple(CompatibilityTupleTests.tuple()),
                         entries: [TestedCompatibilityTuple] = [TestedCompatibilityTupleTests.entry()],
                         rules: [CompatibilityIncompatibility] = [],
                         history: [ConnectionVerificationRecord] = []) throws -> CompatibilityState {
        let manifest = try CompatibilityManifest(manifestVersion: 1, tested: entries, incompatibilities: rules)
        return CompatibilityEvaluator.evaluate(observed: observed, manifest: manifest, history: history)
    }

    static func record(_ tuple: CompatibilityTuple = CompatibilityTupleTests.tuple(), at time: Double = 1_700_000_000) throws -> ConnectionVerificationRecord {
        try ConnectionVerificationRecord(tuple: tuple, verifiedAt: Date(timeIntervalSince1970: time), evidence: .userConfirmedWorkspaceOpened)
    }

    @Test func testedAndUntestedCombinationsNeedRealConnectionEvidence() throws {
        #expect(try Self.evaluate() == .needsValidation(.neverConnected))
        #expect(try Self.evaluate(entries: []) == .needsValidation(.untestedCombination))
        let bundled = try CompatibilityManifest.bundled()
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(CompatibilityTupleTests.tuple()), manifest: bundled, history: []) == .needsValidation(.untestedCombination))
    }

    @Test(arguments: [false, true])
    func newestMatchingHistoryWinsRegardlessOfUnrelatedHistoryAndOrdering(_ reversed: Bool) throws {
        let old = try Self.record()
        let latest = try Self.record(at: 1_700_003_600)
        var otherTuple = old.tuple
        otherTuple.codexCLIVersion = "0.40.0"
        let other = try Self.record(otherTuple, at: 1_700_007_200)
        let history = [other, old, latest]
        let state = try Self.evaluate(history: reversed ? Array(history.reversed()) : history)
        #expect(state == .verified(recordedAt: latest.verifiedAt))
        #expect(state.allowsHandoff)
    }

    @Test(arguments: CompatibilityField.allCases)
    func everyUnknownFieldPreventsVerification(_ field: CompatibilityField) throws {
        let record = try Self.record()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record.tuple)) as? [String: Any])
        object.removeValue(forKey: field.rawValue)
        let observed = try JSONDecoder().decode(ObservedTuple.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try Self.evaluate(observed, history: [record]) == .needsValidation(.unknownFields([field])))
    }

    @Test func driftIncludesProviderVersionsBuildsPathsAndCapabilities() throws {
        let record = try Self.record()
        let replacements: [CompatibilityField: Any] = [
            .hostMacOSVersion: "27", .hostMacOSBuild: "26A1", .codexDesktopVersion: "2",
            .codexDesktopBuild: "2000", .codexDesktopPath: "/Applications/Codex Beta.app",
            .runtimeProtocolVersion: 2, .runtimeProvider: "tart", .runtimeVersion: "2.36.0",
            .guestMacOSBuild: "26B1", .xcodeBuild: "18A1", .codexCLIVersion: "0.51.0",
            .codexCLIPath: "/usr/local/bin/codex", .codexCLICapabilities: ["changed"],
            .githubCLIVersion: "3", .provisioningScriptVersion: "b7255bd"
        ]
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record.tuple)) as? [String: Any])
        for (field, value) in replacements {
            var object = original
            object[field.rawValue] = value
            let observed = try JSONDecoder().decode(ObservedTuple.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(try Self.evaluate(observed, history: [record]) == .needsValidation(.changedSinceLastVerified([field])))
        }
        #expect(replacements.count == CompatibilityField.allCases.count - 1)
    }

    @Test func missingAndCompetingInstallationsTakePriorityOverUnknownPaths() throws {
        var observed = ObservedTuple(CompatibilityTupleTests.tuple())
        observed.codexCLIVersion = nil
        observed.codexCLIPath = nil
        observed.codexCLIInstallations = 0
        #expect(try Self.evaluate(observed, history: [Self.record()]) == .needsValidation(.codexCLIMissing))
        observed.codexCLIInstallations = 3
        #expect(try Self.evaluate(observed, history: [Self.record()]) == .needsValidation(.competingInstallations(count: 3)))
        observed.codexCLIInstallations = -1
        #expect(try Self.evaluate(observed) == .needsValidation(.unknownFields([.codexCLIInstallations])))
    }

    @Test(arguments: [-1, 0])
    func nonpositiveProtocolCannotMatchStoredOrManifestEvidence(_ version: Int) throws {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.runtimeProtocolVersion = version
        let entry = TestedCompatibilityTupleTests.entry(tuple, verification: TestedCompatibilityTupleTests.verification())
        #expect(try Self.evaluate(ObservedTuple(tuple), entries: [entry], history: [Self.record()]) == .needsValidation(.unknownFields([.runtimeProtocolVersion])))
    }

    @Test func malformedKnownValuesNeedReobservationNotApproval() throws {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexCLIPath = "/"
        let entry = TestedCompatibilityTupleTests.entry(tuple, verification: TestedCompatibilityTupleTests.verification())
        #expect(try Self.evaluate(ObservedTuple(tuple), entries: [entry]) == .needsValidation(.unknownFields([.codexCLIPath])))
        tuple = CompatibilityTupleTests.tuple()
        tuple.codexCLICapabilities = Array(repeating: "same", count: 65)
        #expect(try Self.evaluate(ObservedTuple(tuple)) == .needsValidation(.unknownFields([.codexCLICapabilities])))
    }

    @Test func knownBlockTakesPriorityOverBothSourcesOfSuccessfulHistory() throws {
        let tuple = CompatibilityTupleTests.tuple()
        let rule = CompatibilityIncompatibility(codexCLIVersion: tuple.codexCLIVersion, reason: .incompatibleComponent(.codexCLIVersion))
        let entry = TestedCompatibilityTupleTests.entry(verification: TestedCompatibilityTupleTests.verification())
        let state = try Self.evaluate(entries: [entry], rules: [rule], history: [Self.record()])
        #expect(state == .incompatible(reason: rule.reason, recoveryActions: rule.recoveryActions))
        #expect(!state.allowsHandoff)
        var unknown = ObservedTuple(tuple)
        unknown.codexCLIVersion = nil
        #expect(try Self.evaluate(unknown, rules: [rule]) == .needsValidation(.unknownFields([.codexCLIVersion])))
    }

    @Test func repairingDuplicateInstallationsClearsOnlyTheCountSpecificBlock() throws {
        let rule = CompatibilityIncompatibility(codexCLIInstallations: 2, reason: .incompatibleComponent(.codexCLIInstallations))
        let manifest = try CompatibilityManifest(manifestVersion: 1, tested: [], incompatibilities: [rule])
        let decodedRules = try CompatibilityManifest.decode(from: JSONEncoder().encode(manifest)).incompatibilities
        let history = [try Self.record()]
        var observed = ObservedTuple(CompatibilityTupleTests.tuple())
        observed.codexCLIInstallations = 2
        #expect(try Self.evaluate(observed, rules: decodedRules, history: history) == .incompatible(reason: rule.reason, recoveryActions: rule.recoveryActions))
        observed.codexCLIInstallations = 1
        #expect(try Self.evaluate(observed, rules: decodedRules, history: history) == .verified(recordedAt: history[0].verifiedAt))
        observed.codexCLIInstallations = nil
        #expect(try Self.evaluate(observed, rules: decodedRules, history: history) == .needsValidation(.unknownFields([.codexCLIInstallations])))
    }

    @Test func firstMatchingRuleAndItsTargetedRecoveryArePreserved() throws {
        let first = CompatibilityIncompatibility(provisioningScriptVersion: "1", reason: .incompatibleComponent(.provisioningScriptVersion), recoveryActions: [.repair(.runtime)])
        let second = CompatibilityIncompatibility(reason: .knownIncompatibleCombination)
        #expect(try Self.evaluate(rules: [first, second]) == .incompatible(reason: first.reason, recoveryActions: first.recoveryActions))
        #expect(try Self.evaluate(rules: [second, first]) == .incompatible(reason: second.reason, recoveryActions: second.recoveryActions))
    }

    @Test(arguments: [false, true])
    func latestCoveringManifestEvidenceWinsAndBeatsUnrelatedHistory(_ reversed: Bool) throws {
        let tuple = CompatibilityTupleTests.tuple()
        var otherHost = tuple
        otherHost.hostMacOSBuild = "25F99"
        var otherCLI = tuple
        otherCLI.codexCLIVersion = "0.40.0"
        let entries = [
            TestedCompatibilityTupleTests.entry(),
            TestedCompatibilityTupleTests.entry(verification: TestedCompatibilityTupleTests.verification(at: 1_700_000_000)),
            TestedCompatibilityTupleTests.entry(verification: TestedCompatibilityTupleTests.verification(at: 1_700_003_600)),
            TestedCompatibilityTupleTests.entry(verification: TestedCompatibilityTupleTests.verification(otherHost, at: 1_700_007_200)),
            TestedCompatibilityTupleTests.entry(otherCLI, verification: TestedCompatibilityTupleTests.verification(otherCLI, at: 1_700_010_800))
        ]
        let state = try Self.evaluate(entries: reversed ? Array(entries.reversed()) : entries, history: [Self.record(otherCLI)])
        #expect(state == .verified(recordedAt: Date(timeIntervalSince1970: 1_700_003_600)))
    }

    @Test func evidenceForAnotherHostBuildDoesNotVerifyButExplainsWhy() throws {
        let entry = TestedCompatibilityTupleTests.entry(verification: TestedCompatibilityTupleTests.verification())
        var otherHost = CompatibilityTupleTests.tuple()
        otherHost.hostMacOSBuild = "25F99"
        #expect(try Self.evaluate(ObservedTuple(otherHost), entries: [entry]) == .needsValidation(.verifiedOnDifferentHost))
        #expect(try Self.evaluate(ObservedTuple(otherHost), entries: [entry], history: [Self.record()]) == .needsValidation(.changedSinceLastVerified([.hostMacOSBuild])))
    }

    @Test func canonicalCapabilitiesStillMatchSuccessfulHistory() throws {
        var tuple = CompatibilityTupleTests.tuple(capabilities: ["a", "b"])
        let record = try Self.record(tuple)
        tuple.codexCLICapabilities = ["b", "a", "b"]
        #expect(try Self.evaluate(ObservedTuple(tuple), history: [record]) == .verified(recordedAt: record.verifiedAt))
    }

    @Test func everyStateRoundTripsWithoutRawErrorPayloads() throws {
        let states: [CompatibilityState] = [
            .verified(recordedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .needsValidation(.unknownFields([.runtimeProvider])), .needsValidation(.competingInstallations(count: 2)),
            .needsValidation(.codexCLIMissing), .needsValidation(.neverConnected), .needsValidation(.verifiedOnDifferentHost),
            .needsValidation(.changedSinceLastVerified([.codexDesktopPath])), .needsValidation(.untestedCombination),
            .incompatible(reason: .knownIncompatibleCombination, recoveryActions: CompatibilityIncompatibility.defaultRecoveryActions)
        ]
        for state in states {
            let decoded = try JSONDecoder().decode(CompatibilityState.self, from: JSONEncoder().encode(state))
            #expect(decoded == state)
            if case .verified = state { #expect(decoded.allowsHandoff) } else { #expect(!decoded.allowsHandoff) }
        }
        let raw = Data(#"{"incompatible":{"reason":"syntheticOpaque","recoveryActions":[]}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CompatibilityState.self, from: raw) }
    }
}
