import Foundation
import GuesthouseCore
import Testing

struct TestedCompatibilityTupleTests {
    static func entry(_ tuple: CompatibilityTuple = CompatibilityTupleTests.tuple(),
                      verification: ManifestConnectionVerification? = nil) -> TestedCompatibilityTuple {
        TestedCompatibilityTuple(
            hostMacOS: VersionRange(minimum: SemanticVersion([26]), maximum: SemanticVersion([27])),
            codexDesktopVersion: tuple.codexDesktopVersion, codexDesktopBuild: tuple.codexDesktopBuild,
            codexDesktopPath: tuple.codexDesktopPath, runtimeProtocolVersion: tuple.runtimeProtocolVersion,
            runtimeProvider: tuple.runtimeProvider, runtimeVersion: tuple.runtimeVersion,
            guestMacOSBuild: tuple.guestMacOSBuild, xcodeBuild: tuple.xcodeBuild,
            codexCLIVersion: tuple.codexCLIVersion, codexCLIPath: tuple.codexCLIPath,
            codexCLICapabilities: tuple.codexCLICapabilities, githubCLIVersion: tuple.githubCLIVersion,
            provisioningScriptVersion: tuple.provisioningScriptVersion, verification: verification
        )
    }

    static func verification(_ tuple: CompatibilityTuple = CompatibilityTupleTests.tuple(),
                             at time: Double = 1_700_000_000) -> ManifestConnectionVerification {
        ManifestConnectionVerification(verifiedAt: Date(timeIntervalSince1970: time),
            hostMacOSVersion: tuple.hostMacOSVersion, hostMacOSBuild: tuple.hostMacOSBuild,
            evidence: "docs/phase0/synthetic-test-only.md")
    }

    @Test(arguments: VMProvider.allCases)
    func exactIdentitySurvivesRoundTrip(_ provider: VMProvider) throws {
        let tuple = CompatibilityTupleTests.tuple(provider: provider)
        let entry = Self.entry(tuple, verification: Self.verification(tuple))
        let decoded = try JSONDecoder().decode(TestedCompatibilityTuple.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
        #expect(Set([entry, decoded]).count == 1)
        #expect(decoded.matches(tuple))
        #expect(decoded.isVerified)
        #expect(decoded.verification?.covers(tuple) == true)
    }

    @Test func equalVersionsFromAnotherProviderDoNotMatch() {
        let entry = Self.entry(CompatibilityTupleTests.tuple(provider: .tart))
        #expect(!entry.matches(CompatibilityTupleTests.tuple(provider: .lume)))
    }

    @Test func testedHostRangeDoesNotBroadenRecordedEvidence() {
        let original = CompatibilityTupleTests.tuple()
        let entry = Self.entry(original, verification: Self.verification(original))
        var observation = original
        observation.hostMacOSBuild = "25F84"
        #expect(entry.matches(observation))
        #expect(entry.verification?.covers(observation) == false)
        observation = original
        observation.hostMacOSVersion = SemanticVersion([27])
        #expect(entry.matches(observation))
        #expect(entry.verification?.covers(observation) == false)
        observation.hostMacOSVersion = SemanticVersion([28])
        #expect(!entry.matches(observation))
    }

    @Test func unverifiedCandidateDoesNotAcquireEvidence() throws {
        let entry = Self.entry()
        #expect(!entry.isVerified)
        #expect(entry.verification == nil)
        #expect(try JSONDecoder().decode(TestedCompatibilityTuple.self, from: JSONEncoder().encode(entry)).verification == nil)
    }

    @Test(arguments: ["runtimeProvider", "runtimeVersion", "codexCLICapabilities"])
    func requiredIdentityCannotBeDefaultedFromOldManifest(_ key: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.entry())) as? [String: Any])
        object.removeValue(forKey: key)
        object["tartVersion"] = "2.36.0"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TestedCompatibilityTuple.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func duplicateCapabilitiesAreCanonicalButOverLimitCannotMatch() throws {
        let tuple = CompatibilityTupleTests.tuple(capabilities: ["b", "a", "b"])
        let entry = Self.entry(tuple)
        #expect(entry.codexCLICapabilities == ["a", "b"])
        #expect(entry.matches(CompatibilityTupleTests.tuple(capabilities: ["a", "b"])))
        let oversized = CompatibilityTupleTests.tuple(capabilities: Array(repeating: "same", count: 65))
        #expect(!Self.entry(oversized).matches(oversized))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TestedCompatibilityTuple.self, from: JSONEncoder().encode(Self.entry(oversized)))
        }
    }

    @Test(arguments: [-1, 0, 2])
    func aTestedEntryCannotApproveAnInvalidInstallationCount(_ count: Int) {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexCLIInstallations = count
        #expect(!Self.entry(tuple).matches(tuple))
    }

    @Test func matchingMalformedIdentityIsNotVerification() {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexDesktopVersion = "1.0\nsyntheticOpaque"
        #expect(!Self.entry(tuple, verification: Self.verification(tuple)).matches(tuple))
        tuple = CompatibilityTupleTests.tuple()
        tuple.runtimeProtocolVersion = 0
        #expect(!Self.entry(tuple).matches(tuple))
    }

    @Test func allNonHostIdentityChangesInvalidateEntry() throws {
        let tuple = CompatibilityTupleTests.tuple()
        let entry = Self.entry(tuple)
        let replacements: [CompatibilityField: Any] = [
            .codexDesktopVersion: "2", .codexDesktopBuild: "2000", .codexDesktopPath: "/Applications/Codex Beta.app",
            .runtimeProtocolVersion: 2, .runtimeProvider: "tart", .runtimeVersion: "2.36.0",
            .guestMacOSBuild: "26B1", .xcodeBuild: "18A1", .codexCLIVersion: "0.51.0",
            .codexCLIPath: "/usr/local/bin/codex", .codexCLIInstallations: 2,
            .codexCLICapabilities: ["changed"], .githubCLIVersion: "3", .provisioningScriptVersion: "2"
        ]
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tuple)) as? [String: Any])
        for (field, value) in replacements {
            var object = original
            object[field.rawValue] = value
            let changed = try JSONDecoder().decode(CompatibilityTuple.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(!entry.matches(changed), "Changed \(field) must invalidate the entry")
        }
        #expect(replacements.count == CompatibilityField.allCases.count - 2)
    }

    @Test(arguments: [0.1, 0.5, 0.9])
    func manifestTimestampHasStableWholeSecondIdentity(_ fraction: Double) throws {
        let verification = Self.verification(at: 1_700_000_000 + fraction)
        let data = try JSONEncoder().encode(verification)
        let decoded = try JSONDecoder().decode(ManifestConnectionVerification.self, from: data)
        #expect(decoded == verification)
        #expect(Set([verification, decoded]).count == 1)
        #expect(verification.verifiedAt.timeIntervalSince1970 == (1_700_000_000 + fraction).rounded())
    }

    @Test func fractionalWireTimestampIsNormalized() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.verification())) as? [String: Any])
        object["verifiedAt"] = "2023-11-14T22:13:20.900Z"
        let decoded = try JSONDecoder().decode(ManifestConnectionVerification.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.verifiedAt == Date(timeIntervalSince1970: 1_700_000_001))
    }

    @Test(arguments: ["syntheticOpaque", String(repeating: "1", count: 129),
                      "2023-11-14T22:13:20Zjunk", "2023-11-14T22:13:20.900Zjunk",
                      "2023-11-14T22:13:20Z\n", "2023-11-14T22:13:20Z ",
                      "prefix2023-11-14T22:13:20Z", "2023-11-14T23:13:20+01:00junk"])
    func malformedDateErrorsDoNotQuoteInput(_ text: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.verification())) as? [String: Any])
        object["verifiedAt"] = text
        do {
            _ = try JSONDecoder().decode(ManifestConnectionVerification.self, from: JSONSerialization.data(withJSONObject: object))
            Issue.record("Expected a date decoding error")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(!context.debugDescription.contains(text))
            #expect(context.underlyingError == nil)
        }
    }

    @Test(arguments: ["2023-11-14T22:13:20Z", "2023-11-14T22:13:20.000Z", "2023-11-14T23:13:20+01:00"])
    func completeTimestampsRemainSupported(_ text: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.verification())) as? [String: Any])
        object["verifiedAt"] = text
        let decoded = try JSONDecoder().decode(ManifestConnectionVerification.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.verifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
