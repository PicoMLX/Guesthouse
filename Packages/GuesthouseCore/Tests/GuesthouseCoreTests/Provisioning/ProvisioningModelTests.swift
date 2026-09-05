import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningModelTests {
    let op = OperationID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let failure = GuesthouseError.guestNotReachable(EnvironmentID())
    let evidence = ResumeEvidence(summary: "restore image 62% downloaded", stagingPath: "downloads/restore.ipsw.partial")
    let pending = EffectToken(1)

    func checkpoint(_ stage: ProvisioningStage) -> Checkpoint { Checkpoint(stage: stage, reachedAt: now) }
    func state(_ stage: ProvisioningStage, _ status: StageStatus) -> ProvisioningState { ProvisioningState(stage: stage, status: status) }

    @Test func readinessRequiresTheFinalCheckpointItself() {
        #expect(!state(.ready, .persistingCheckpoint(checkpoint(.ready), operation: op, write: pending)).isReady)
        #expect(state(.ready, .completed(checkpoint(.ready))).isReady)
        #expect(!ProvisioningState.isConsistent(stage: .ready, status: .completed(checkpoint(.preflight))))
        #expect(ProvisioningState.isConsistent(stage: .ready, status: .notStarted))
    }

    @Test func resumeEvidenceIsRedactedAndBoundedAtConstruction() throws {
        let evidence = ResumeEvidence(summary: "download resumed with token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab\nnext", stagingPath: "downloads/restore.partial")
        #expect(evidence.summary.hasPrefix("download resumed with token [redacted:github-token]"))
        #expect(!evidence.summary.contains("\n"))
        #expect(evidence.stagingPath == "downloads/restore.partial")
        let long = ResumeEvidence(summary: String(repeating: "s", count: 5_000))
        #expect(long.summary.unicodeScalars.count == 201, "200 scalars and an ellipsis")
        let decoded = try JSONDecoder().decode(ResumeEvidence.self, from: Data("{\"summary\":\"password: hunter2\"}".utf8))
        #expect(decoded.summary == "password: [redacted:secret]")
    }

    @Test func stateRoundTripsThroughJSONAndRejectsInconsistentCheckpoints() throws {
        let states = [
            ProvisioningState.initial,
            state(.sshPaired, .recoverableFailure(failure, interrupted: nil)),
            state(.macOSInstalled, .unknownOutcome(op, inspection: pending)),
            state(.runtimeReady, .resumable(evidence)),
            state(.runtimeReady, .cleanupRequired(failure, cleanup: pending)),
            state(.ready, .completed(checkpoint(.ready))),
        ]
        for original in states {
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(ProvisioningState.self, from: data) == original)
        }
        let inconsistent = Data("""
        {"schemaVersion":1,"stage":"ready","issuedEffects":0,"status":{"completed":{"_0":{"stage":"preflight","reachedAt":0}}}}
        """.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: inconsistent) }
        let unversioned = Data("""
        {"stage":"preflight","issuedEffects":0,"status":{"notStarted":{}}}
        """.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: unversioned) }
        let encoded = String(decoding: try JSONEncoder().encode(ProvisioningState.initial), as: UTF8.self)
        #expect(encoded.contains("\"schemaVersion\":1"))
    }

    @Test(arguments: ["-1", "true", #""1""#, "1.5", "18446744073709551615", "9223372036854775808"])
    func malformedStartRequestTokensAreRejectedWhenDecoded(request: String) {
        let record = Data("{\"schemaVersion\":1,\"stage\":\"preflight\",\"issuedEffects\":0,\"status\":{\"startRequested\":{\"request\":\(request)}}}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: record) }
    }
}
