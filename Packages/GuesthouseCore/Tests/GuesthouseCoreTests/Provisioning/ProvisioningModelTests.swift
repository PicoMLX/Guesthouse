import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningModelTests {
    @Test(arguments: ProvisioningStage.allCases)
    func readinessRequiresThePersistedFinalCheckpoint(stage: ProvisioningStage) {
        let checkpoint = Checkpoint(stage: stage, reachedAt: Date(timeIntervalSince1970: 0))
        let writing = ProvisioningState(stage: stage, status: .persistingCheckpoint(checkpoint, operation: OperationID(), write: EffectToken(1)))
        #expect(!writing.isReady)
        #expect(ProvisioningState(stage: stage, status: .completed(checkpoint)).isReady == (stage == .ready))
        #expect(!ProvisioningState(stage: stage, status: .notStarted).isReady)
    }

    @Test(arguments: [
        StageStatus.notStarted, .startRequested(request: nil, resuming: nil),
        .startRequested(request: EffectToken(9), resuming: ResumeEvidence(kind: .partialDownload)),
        .inProgress(OperationID()),
        .persistingCheckpoint(Checkpoint(stage: .first, reachedAt: Date(timeIntervalSince1970: 0)), operation: OperationID(), write: EffectToken(9)),
        .completed(Checkpoint(stage: .first, reachedAt: Date(timeIntervalSince1970: 0))),
        .canceled, .recoverableFailure(.runtimeMissing, interrupted: OperationID()),
        .startRejected(.runtimeMissing, resuming: ResumeEvidence(kind: .installationStaging)),
        .needsUserAction(OperationID(), .credentialsLocked(.guestKeychain)),
        .unknownOutcome(OperationID(), inspection: EffectToken(9)), .awaitingInspection(EffectToken(9)),
        .resumable(ResumeEvidence(kind: .unfinishedCopy)!),
        .cleanupRequired(.runtimeMissing, cleanup: EffectToken(9)),
    ])
    func everyStatusPreservesIdentityAndEvidenceThroughJSON(status: StageStatus) throws {
        let original = ProvisioningState(stage: .first, status: status, issuedEffects: 5)
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.issuedEffects >= (restored.status.pendingEffect?.value ?? 0))
        #expect(restored.isConsistent)
    }

    @Test(arguments: [
        #"{"completed":{"_0":{"stage":"preflight","reachedAt":0}}}"#,
        #"{"persistingCheckpoint":{"_0":{"stage":"preflight","reachedAt":0},"write":1}}"#,
    ])
    func mismatchedCheckpointStagesAreRefused(status: String) {
        let fixture = Data("{\"schemaVersion\":2,\"stage\":\"ready\",\"issuedEffects\":1,\"status\":\(status)}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: fixture) }
    }

    @Test(arguments: ["-1", "true", #""1""#, "1.5", "18446744073709551616"],
          [#"{"startRequested":{"request":TOKEN}}"#, #"{"awaitingInspection":{"_0":TOKEN}}"#])
    func malformedOrOutOfRangePendingTokensAreRefused(token: String, status: String) {
        let payload = status.replacingOccurrences(of: "TOKEN", with: token)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProvisioningState.self, from: record(issued: "0", status: payload))
        }
    }

    @Test(arguments: ["-1", "true", #""1""#, "1.5", "18446744073709551616"])
    func malformedOrOutOfRangeCountersAreRefused(issued: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: record(issued: issued)) }
    }

    @Test(arguments: [UInt64(0), 9, UInt64.max / 2, UInt64.max / 2 + 1, UInt64.max - 1], [false, true])
    func mintedTokensRemainDecodableAcrossCounterBoundaries(value: UInt64, promotedFromPending: Bool) throws {
        let status = promotedFromPending ? "{\"startRequested\":{\"request\":\(value)}}" : #"{"notStarted":{}}"#
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: record(issued: promotedFromPending ? "0" : String(value), status: status))
        #expect(restored.issuedEffects == value)
        let token = try #require(restored.nextEffectToken)
        #expect(token.value == value + 1)
        let next = ProvisioningState(stage: .first, status: .awaitingInspection(token), issuedEffects: restored.issuedEffects)
        let relaunched = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(next))
        #expect(relaunched == next)
        #expect(relaunched.issuedEffects == token.value)
        #expect(relaunched.nextEffectToken == (value == UInt64.max - 1 ? nil : EffectToken(value + 2)))
    }

    @Test(arguments: [false, true])
    func exhaustedCountersPreserveOutstandingIdentityWithoutMinting(promotedFromPending: Bool) throws {
        let status = promotedFromPending ? "{\"awaitingInspection\":{\"_0\":\(UInt64.max)}}" : #"{"notStarted":{}}"#
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: record(issued: promotedFromPending ? "0" : String(UInt64.max), status: status))
        #expect(restored.issuedEffects == UInt64.max)
        #expect(restored.nextEffectToken == nil)
        #expect(restored.status.pendingEffect == (promotedFromPending ? EffectToken(UInt64.max) : nil))
        #expect(try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(restored)) == restored)
    }

    @Test(arguments: [UInt64(0), 1, 9, UInt64.max])
    func tokensRoundTripWithoutTruncation(value: UInt64) throws {
        let token = EffectToken(value)
        #expect(try JSONDecoder().decode(EffectToken.self, from: JSONEncoder().encode(token)) == token)
    }

    private func record(issued: String, status: String = #"{"notStarted":{}}"#) -> Data {
        Data("{\"schemaVersion\":2,\"stage\":\"preflight\",\"issuedEffects\":\(issued),\"status\":\(status)}".utf8)
    }
}

@Suite struct ProvisioningSchemaTests {
    @Test func typedProvisioningLayoutKeepsItsOwnVersion() throws {
        let fixture = Data(#"{"schemaVersion":2,"stage":"preflight","issuedEffects":0,"status":{"notStarted":{}}}"#.utf8)
        #expect(ProvisioningState.currentSchema.rawValue == 2)
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: fixture)
        #expect(restored == .initial)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(encoded["schemaVersion"] as? Int == 2)
    }

    @Test(arguments: ["0", "-1", "1", "3", "999", "true", #""2""#])
    func unsupportedLayoutsIncludingLegacyPrototypeAreRefused(version: String) {
        let fixture = Data("{\"schemaVersion\":\(version),\"stage\":\"preflight\",\"issuedEffects\":0,\"status\":{\"notStarted\":{}}}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: fixture) }
    }

    @Test func unversionedAndRawSummaryLegacyRecordsAreNotReinterpreted() {
        let unversioned = Data(#"{"stage":"preflight","issuedEffects":0,"status":{"notStarted":{}}}"#.utf8)
        let legacy = Data(#"{"schemaVersion":1,"stage":"preflight","issuedEffects":9,"status":{"startRequested":{"resuming":{"summary":"old raw output","stagingPath":"downloads/restore.partial"}}}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: unversioned) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: legacy) }
    }

    @Test func tokenlessTypedReservationsRemainInspectionOnly() throws {
        let fixture = Data(#"{"schemaVersion":2,"stage":"preflight","issuedEffects":9,"status":{"startRequested":{"resuming":{"kind":"partialDownload","stagingPath":"downloads/restore.partial"}}}}"#.utf8)
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: fixture)
        #expect(restored.status == .startRequested(request: nil, resuming: ResumeEvidence(kind: .partialDownload, stagingPath: "downloads/restore.partial")))
        #expect(restored.status.pendingEffect == nil)
        #expect(restored.issuedEffects == 9)
    }
}

@Suite struct ResumeEvidenceTests {
    @Test(arguments: [
        (ResumeEvidence.Kind.partialDownload, "An interrupted download has partial data to inspect before resuming."),
        (.installationStaging, "An interrupted installation has staging data to inspect before resuming."),
        (.unfinishedCopy, "An interrupted copy has partial data to inspect before resuming."),
    ])
    func presentationUsesOnlyFixedTemplates(kind: ResumeEvidence.Kind, expected: String) throws {
        let evidence = try #require(ResumeEvidence(kind: kind, stagingPath: "staging/not-display-text"))
        #expect(evidence.summary == expected)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        #expect(Set(object.keys) == ["kind", "stagingPath"])
    }

    @Test(arguments: [
        "downloads/Cafe\u{0301} restore.ipsw.partial",
        "downloads/My Restore Images/Cafe\u{0301} 62%.ipsw.partial", "staging/a b c",
        "downloads/" + String(repeating: "d", count: 500) + ".partial",
        "staging/literal%2e%2e.partial", String(repeating: "é", count: 512),
    ])
    func stagingLocationsPreserveExactBytes(path: String) throws {
        let evidence = try #require(ResumeEvidence(kind: .partialDownload, stagingPath: path))
        let decoded = try JSONDecoder().decode(ResumeEvidence.self, from: JSONEncoder().encode(evidence))
        #expect(Array(try #require(decoded.stagingPath).utf8) == Array(path.utf8))
    }

    @Test(arguments: [
        "", "/Volumes/staging/restore.partial", "~/staging/restore.partial", "../../etc/passwd",
        "downloads//restore.partial", "downloads/./restore.partial", "downloads/../restore.partial",
        "downloads/restore.partial/", "downloads/\u{202E}restore.partial", "downloads/restore\npartial",
        "downloads/\0partial", "downloads/\u{200B}partial", "downloads/\u{E000}partial",
        String(repeating: "d", count: 1_025), String(repeating: "é", count: 513),
    ])
    func invalidLocationsFailInsteadOfBeingSilentlyDropped(path: String) throws {
        #expect(ResumeEvidence(kind: .partialDownload, stagingPath: path) == nil)
        let data = try JSONSerialization.data(withJSONObject: ["kind": "partialDownload", "stagingPath": path])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ResumeEvidence.self, from: data) }
    }

    @Test func rawSummaryAndUnknownFieldsCannotBeForwarded() throws {
        let data = Data(#"{"kind":"partialDownload","summary":"test-only-raw-response","extra":{"authorization":"test-only-header"}}"#.utf8)
        let evidence = try JSONDecoder().decode(ResumeEvidence.self, from: data)
        #expect(evidence.stagingPath == nil)
        #expect(evidence.summary == "An interrupted download has partial data to inspect before resuming.")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        #expect(Set(object.keys) == ["kind"])
    }

    @Test(arguments: [#"{"summary":"old raw response"}"#, #"{"kind":"unknown"}"#, #"{"kind":42}"#, #"{"kind":"partialDownload","stagingPath":42}"#])
    func malformedEvidenceIsRefused(json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ResumeEvidence.self, from: Data(json.utf8)) }
    }
}
