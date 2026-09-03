import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningReducerHardeningTests {
    let operation = OperationID()
    let checkpoint = Checkpoint(stage: .first, reachedAt: Date(timeIntervalSince1970: 1_800_000_000))

    func state(_ status: StageStatus) -> ProvisioningState { ProvisioningState(stage: .first, status: status) }

    @Test func aFailedCheckpointWriteIsAFailureWithRecoveryNotALoop() throws {
        let failed = try ProvisioningReducer.reduce(state(.persistingCheckpoint(checkpoint)), .checkpointPersistenceFailed(.insufficientDisk(requiredBytes: 2, availableBytes: 1, volumePath: "/")))
        #expect(failed.effects.isEmpty)
        guard case .recoverableFailure(let error) = failed.state.status else { Issue.record("expected recoverableFailure"); return }
        #expect(error.recoveryActions.contains(.freeDiskSpace))
        let retried = try ProvisioningReducer.reduce(failed.state, .userRetried)
        #expect(retried.state.status == .awaitingInspection)
        let persisted = try ProvisioningReducer.reduce(retried.state, .reconciled(.completed(checkpoint)))
        #expect(persisted.effects == [.persistCheckpoint(checkpoint)])
    }

    @Test func interruptedCheckpointWritesAndCleanupsAreInspected() throws {
        let write = try ProvisioningReducer.reduce(state(.persistingCheckpoint(checkpoint)), .connectionInterrupted(operation))
        #expect(write.state.status == .awaitingInspection)
        #expect(write.effects == [.inspectActualState(.first)])
        let cleanup = try ProvisioningReducer.reduce(state(.cleanupRequired(.canceled)), .connectionInterrupted(operation))
        #expect(cleanup.state.status == .awaitingInspection)
        let cleanupRetry = try ProvisioningReducer.reduce(state(.cleanupRequired(.canceled)), .userRetried)
        #expect(cleanupRetry.effects == [.inspectActualState(.first)])
    }

    @Test func aStillRunningOperationResumesMonitoringUnderItsIdentity() throws {
        let resumed = try ProvisioningReducer.reduce(state(.unknownOutcome(operation)), .reconciled(.stillRunning(operation)))
        #expect(resumed.state.status == .inProgress(operation))
        #expect(resumed.effects.isEmpty)
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(resumed.state, .startRequested(stage: .first))
        }
    }

    @Test func connectionLossWhileAwaitingUserActionBecomesUnknown() throws {
        let lost = try ProvisioningReducer.reduce(state(.needsUserAction(operation, .loginExpired(.github))), .connectionInterrupted(operation))
        #expect(lost.state.status == .unknownOutcome(operation))
        #expect(lost.effects == [.inspectActualState(.first)])
    }

    @Test func aSecondInspectionRequestWhilePendingIssuesNothing() throws {
        let first = try ProvisioningReducer.reduce(state(.canceled), .userRetried)
        #expect(first.effects == [.inspectActualState(.first)])
        let second = try ProvisioningReducer.reduce(first.state, .userRetried)
        #expect(second.effects.isEmpty)
        #expect(second.state.status == .awaitingInspection)
    }

    @Test func inspectionCanBeRequestedFromAnyStatusExceptWhileInspecting() throws {
        for status in [StageStatus.notStarted, .startRequested, .inProgress(operation), .completed(checkpoint), .recoverableFailure(.canceled), .startRejected(.canceled), .needsUserAction(operation, .canceled), .cleanupRequired(.canceled), .persistingCheckpoint(checkpoint)] {
            let result = try ProvisioningReducer.reduce(state(status), .inspectionRequested)
            #expect(result.state.status == .awaitingInspection, "\(status.caseName)")
            #expect(result.effects == [.inspectActualState(.first)])
        }
        for status in [StageStatus.awaitingInspection, .unknownOutcome(operation)] {
            #expect(throws: ProvisioningTransitionError.self) { try ProvisioningReducer.reduce(state(status), .inspectionRequested) }
        }
    }

    @Test func resumeEvidenceIsSanitizedLikeAnError() {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let split = ResumeEvidence(summary: "partial download of ghp_\u{200B}ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab")
        #expect(!split.summary.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(split.summary.contains("[redacted:github-token]"))
        let open = ResumeEvidence(summary: "https://user:" + String(repeating: "p", count: 900) + "@host/x")
        #expect(!open.summary.contains("pppp"))
        #expect(ResumeEvidence(summary: token).summary == "[redacted:github-token]")
    }
}
