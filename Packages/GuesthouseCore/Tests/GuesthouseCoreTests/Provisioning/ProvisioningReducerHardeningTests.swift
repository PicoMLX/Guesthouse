import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningReducerHardeningTests {
    let operation = OperationID()
    let stranger = OperationID()
    let checkpoint = Checkpoint(stage: .first, reachedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let outstanding = EffectToken(1)

    func state(_ status: StageStatus) -> ProvisioningState { ProvisioningState(stage: .first, status: status) }

    /// The token the reducer stamped on the effect it just asked for; the coordinator echoes it
    /// back in the callback, and so do these tests.
    func token(of effects: [ProvisioningEffect]) throws -> EffectToken {
        switch try #require(effects.first) {
        case .inspectActualState(_, let token), .persistCheckpoint(_, let token), .cleanUp(_, let token): token
        }
    }

    @Test func aFailedCheckpointWriteIsAFailureWithRecoveryNotALoop() throws {
        let failed = try ProvisioningReducer.reduce(state(.persistingCheckpoint(checkpoint, operation: operation, write: outstanding)), .checkpointPersistenceFailed(outstanding, .insufficientDisk(requiredBytes: 2, availableBytes: 1, volumePath: "/")))
        #expect(failed.effects.isEmpty)
        guard case .recoverableFailure(let error) = failed.state.status else { Issue.record("expected recoverableFailure"); return }
        #expect(error.recoveryActions.contains(.freeDiskSpace))
        let retried = try ProvisioningReducer.reduce(failed.state, .userRetried)
        let persisted = try ProvisioningReducer.reduce(retried.state, .reconciled(try token(of: retried.effects), .completed(checkpoint)))
        #expect(persisted.effects == [.persistCheckpoint(checkpoint, try token(of: persisted.effects))])
    }

    @Test func interruptedCheckpointWritesAndCleanupsAreInspected() throws {
        let write = try ProvisioningReducer.reduce(state(.persistingCheckpoint(checkpoint, operation: operation, write: outstanding)), .connectionInterrupted(operation))
        #expect(write.state.status.caseName == "awaitingInspection")
        #expect(write.effects == [.inspectActualState(.first, try token(of: write.effects))])
        let cleanup = try ProvisioningReducer.reduce(state(.cleanupRequired(.canceled, cleanup: outstanding)), .connectionInterrupted(operation))
        #expect(cleanup.state.status.caseName == "awaitingInspection")
        let cleanupRetry = try ProvisioningReducer.reduce(state(.cleanupRequired(.canceled, cleanup: outstanding)), .userRetried)
        #expect(cleanupRetry.effects == [.inspectActualState(.first, try token(of: cleanupRetry.effects))])
    }

    @Test func aStillRunningOperationResumesMonitoringUnderItsIdentity() throws {
        let resumed = try ProvisioningReducer.reduce(state(.unknownOutcome(operation, inspection: outstanding)), .reconciled(outstanding, .stillRunning(operation)))
        #expect(resumed.state.status == .inProgress(operation))
        #expect(resumed.effects.isEmpty)
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(resumed.state, .startRequested(stage: .first))
        }
    }

    @Test func connectionLossWhileAwaitingUserActionBecomesUnknown() throws {
        let lost = try ProvisioningReducer.reduce(state(.needsUserAction(operation, .loginExpired(.github))), .connectionInterrupted(operation))
        #expect(lost.state.status == .unknownOutcome(operation, inspection: try token(of: lost.effects)))
        #expect(lost.effects == [.inspectActualState(.first, try token(of: lost.effects))])
    }

    /// An inspection whose request was never submitted, whose reply was lost, or that was still
    /// outstanding at relaunch used to leave the reducer with no event that could produce a
    /// `reconciled` result, so provisioning could not be unblocked at all.
    @Test func aLostInspectionIsReissuedAndItsStaleReplyRefused() throws {
        let first = try ProvisioningReducer.reduce(state(.canceled), .userRetried)
        let lost = try token(of: first.effects)
        let second = try ProvisioningReducer.reduce(first.state, .inspectionRequested)
        let live = try token(of: second.effects)
        #expect(live != lost)
        #expect(second.effects == [.inspectActualState(.first, live)])
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: live, actual: lost)) {
            try ProvisioningReducer.reduce(second.state, .reconciled(lost, .notStarted))
        }
        #expect(try ProvisioningReducer.reduce(second.state, .reconciled(live, .notStarted)).state.status == .notStarted)
        // The count survives the journal, so a relaunch cannot mint a token a late reply names.
        let relaunched = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(second.state))
        let afterRelaunch = try ProvisioningReducer.reduce(relaunched, .userRetried)
        #expect(try token(of: afterRelaunch.effects) != live)
    }

    /// A retry while the outcome is unknown used to issue a second inspection that could not be
    /// told apart from the first, so a delayed answer to the first could be taken as the verdict
    /// on an operation started since.
    @Test func aRetryWhileTheOutcomeIsUnknownReplacesTheOutstandingInspection() throws {
        let lost = try ProvisioningReducer.reduce(state(.inProgress(operation)), .connectionInterrupted(operation))
        let first = try token(of: lost.effects)
        let again = try ProvisioningReducer.reduce(lost.state, .userRetried)
        let live = try token(of: again.effects)
        #expect(live != first)
        #expect(again.state.status == .unknownOutcome(operation, inspection: live))
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: live, actual: first)) {
            try ProvisioningReducer.reduce(again.state, .reconciled(first, .completed(checkpoint)))
        }
    }

    /// Inspecting from a live start request would release the reservation while the runtime can
    /// still accept it, so a `notStarted` verdict would let a second start race the first.
    @Test func inspectionIsRefusedWhileAStartRequestIsLive() throws {
        #expect(throws: ProvisioningTransitionError.illegalTransition(status: "startRequested", event: "inspectionRequested")) {
            try ProvisioningReducer.reduce(state(.startRequested), .inspectionRequested)
        }
        let interrupted = try ProvisioningReducer.reduce(state(.startRequested), .startRequestInterrupted)
        #expect(interrupted.state.status.caseName == "awaitingInspection")
    }

    @Test func inspectionCanBeRequestedFromEveryOtherStatus() throws {
        for status in [StageStatus.notStarted, .inProgress(operation), .completed(checkpoint), .recoverableFailure(.canceled), .startRejected(.canceled), .needsUserAction(operation, .canceled), .cleanupRequired(.canceled, cleanup: outstanding), .persistingCheckpoint(checkpoint, operation: nil, write: outstanding), .awaitingInspection(outstanding)] {
            let result = try ProvisioningReducer.reduce(state(status), .inspectionRequested)
            let issued = try token(of: result.effects)
            #expect(result.state.status == .awaitingInspection(issued), "\(status.caseName)")
            #expect(result.effects == [.inspectActualState(.first, issued)], "\(status.caseName)")
        }
        // An unknown outcome keeps the interrupted operation's identity while it inspects again.
        let unknown = try ProvisioningReducer.reduce(state(.unknownOutcome(operation, inspection: outstanding)), .inspectionRequested)
        #expect(unknown.state.status == .unknownOutcome(operation, inspection: EffectToken(2)))
    }

    /// A cleanup whose connection dropped can be reported as finished long after a second
    /// cleanup was launched; accepting it would allow a start against the second one's leftovers.
    @Test func aStaleCleanupCallbackCannotClearANewerCleanup() throws {
        let first = try ProvisioningReducer.reduce(state(.awaitingInspection(outstanding)), .reconciled(outstanding, .failedNeedsCleanup(.canceled)))
        let abandoned = try token(of: first.effects)
        let interrupted = try ProvisioningReducer.reduce(first.state, .connectionInterrupted(operation))
        let second = try ProvisioningReducer.reduce(interrupted.state, .reconciled(try token(of: interrupted.effects), .failedNeedsCleanup(.canceled)))
        let live = try token(of: second.effects)
        #expect(live != abandoned)
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: live, actual: abandoned)) {
            try ProvisioningReducer.reduce(second.state, .cleanupFinished(abandoned))
        }
        #expect(try ProvisioningReducer.reduce(second.state, .cleanupFinished(live)).state.status == .notStarted)
    }

    /// After a crash the journal can be ahead of the saved state. Pinning the saved stage would
    /// offer a start for a step the runtime has already run.
    @Test func reconciliationAdoptsALaterDurableStage() throws {
        let later = Checkpoint(stage: .runtimeReady, reachedAt: checkpoint.reachedAt)
        let adopted = try ProvisioningReducer.reduce(state(.awaitingInspection(outstanding)), .reconciled(outstanding, .completed(later)))
        #expect(adopted.state.stage == .runtimeReady)
        #expect(adopted.state.isConsistent)
        #expect(adopted.effects == [.persistCheckpoint(later, try token(of: adopted.effects))])
        let persisted = try ProvisioningReducer.reduce(adopted.state, .checkpointPersisted(try token(of: adopted.effects), later))
        #expect(persisted.state.status == .completed(later))
        // An older checkpoint is not evidence about this stage and is still refused.
        let ahead = ProvisioningState(stage: .runtimeReady, status: .awaitingInspection(outstanding))
        #expect(throws: ProvisioningTransitionError.stageMismatch(expected: .runtimeReady, actual: .first)) {
            try ProvisioningReducer.reduce(ahead, .reconciled(outstanding, .completed(checkpoint)))
        }
    }

    /// An operation paused at the guest console is still paused when contact comes back. Calling
    /// it "running" would hide the prompt and its recovery actions.
    @Test func aPausedOperationStaysPausedAfterReconciliation() throws {
        let paused = GuesthouseError.credentialsLocked(.guestKeychain)
        let lost = try ProvisioningReducer.reduce(state(.needsUserAction(operation, paused)), .connectionInterrupted(operation))
        let inspection = try token(of: lost.effects)
        let restored = try ProvisioningReducer.reduce(lost.state, .reconciled(inspection, .stillNeedsUserAction(operation, paused)))
        #expect(restored.state.status == .needsUserAction(operation, paused))
        #expect(restored.effects.isEmpty)
        guard case .needsUserAction(_, let error) = restored.state.status else { Issue.record("expected needsUserAction"); return }
        #expect(error.recoveryActions.contains(.openConsole))
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
            try ProvisioningReducer.reduce(lost.state, .reconciled(inspection, .stillNeedsUserAction(stranger, paused)))
        }
        // The user can still report the step done, and that inspects.
        #expect(try ProvisioningReducer.reduce(restored.state, .userActionCompleted).state.status.caseName == "awaitingInspection")
    }

    /// A delayed failure from an abandoned write used to be accepted as the failure of the write
    /// that replaced it, leaving an obsolete persistence error over a durable checkpoint.
    @Test func aStaleCheckpointWriteFailureCannotOverwriteANewerWrite() throws {
        let reached = try ProvisioningReducer.reduce(state(.inProgress(operation)), .checkpointReached(operation, checkpoint))
        let abandoned = try token(of: reached.effects)
        let interrupted = try ProvisioningReducer.reduce(reached.state, .connectionInterrupted(operation))
        let rewritten = try ProvisioningReducer.reduce(interrupted.state, .reconciled(try token(of: interrupted.effects), .completed(checkpoint)))
        let live = try token(of: rewritten.effects)
        #expect(live != abandoned)
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: live, actual: abandoned)) {
            try ProvisioningReducer.reduce(rewritten.state, .checkpointPersistenceFailed(abandoned, .canceled))
        }
        #expect(try ProvisioningReducer.reduce(rewritten.state, .checkpointPersisted(live, checkpoint)).state.status == .completed(checkpoint))
    }

    /// `stillRunning` describes the interrupted operation itself. Adopting a different identity
    /// would leave the original free to keep mutating with its callbacks rejected as mismatches.
    @Test func aReconciledRunningOperationMustBeTheInterruptedOne() throws {
        let lost = try ProvisioningReducer.reduce(state(.inProgress(operation)), .connectionInterrupted(operation))
        let inspection = try token(of: lost.effects)
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
            try ProvisioningReducer.reduce(lost.state, .reconciled(inspection, .stillRunning(stranger)))
        }
        // Inspection after a relaunch knows no identity, so the reported one is the only one.
        let adopted = try ProvisioningReducer.reduce(state(.awaitingInspection(outstanding)), .reconciled(outstanding, .stillRunning(stranger)))
        #expect(adopted.state.status == .inProgress(stranger))
    }

    /// A cleanup that is still running must be monitored, not repeated: a second cleanup would
    /// race the first over the same staging data, and `notStarted` would let provisioning start
    /// while the first cleanup can still remove what it produces.
    @Test func aCleanupThatIsStillRunningIsMonitoredNotDuplicated() throws {
        let requested = try ProvisioningReducer.reduce(state(.awaitingInspection(outstanding)), .reconciled(outstanding, .failedNeedsCleanup(.canceled)))
        let cleanup = try token(of: requested.effects)
        let interrupted = try ProvisioningReducer.reduce(requested.state, .connectionInterrupted(operation))
        let resumed = try ProvisioningReducer.reduce(interrupted.state, .reconciled(try token(of: interrupted.effects), .cleanupRunning(cleanup, .canceled)))
        #expect(resumed.effects.isEmpty)
        #expect(resumed.state.status == .cleanupRequired(.canceled, cleanup: cleanup))
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(resumed.state, .startRequested(stage: .first))
        }
        #expect(try ProvisioningReducer.reduce(resumed.state, .cleanupFinished(cleanup)).state.status == .notStarted)
    }

    /// A delayed interruption belonging to another operation says nothing about this write.
    @Test func anInterruptionFromAnotherOperationDoesNotAbandonTheWrite() throws {
        let reached = try ProvisioningReducer.reduce(state(.inProgress(operation)), .checkpointReached(operation, checkpoint))
        let write = try token(of: reached.effects)
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
            try ProvisioningReducer.reduce(reached.state, .connectionInterrupted(stranger))
        }
        #expect(try ProvisioningReducer.reduce(reached.state, .checkpointPersisted(write, checkpoint)).state.status == .completed(checkpoint))
        #expect(try ProvisioningReducer.reduce(reached.state, .connectionInterrupted(operation)).state.status.caseName == "awaitingInspection")
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

    /// A staging path has to name the file the next attempt will look for, so display
    /// sanitizing would break it: dropping the combining mark in a decomposed `Café.partial`
    /// names a file that does not exist. It is kept scalar for scalar or refused outright.
    @Test func aStagingPathIsKeptExactlyOrRefused() throws {
        let decomposed = "downloads/Cafe\u{0301} restore.ipsw.partial"
        let kept = ResumeEvidence(summary: "62% downloaded", stagingPath: decomposed)
        #expect(kept.stagingPath == decomposed)
        #expect(kept.stagingPath?.unicodeScalars.count == decomposed.unicodeScalars.count)
        let restored = try JSONDecoder().decode(ResumeEvidence.self, from: JSONEncoder().encode(kept))
        #expect(restored.stagingPath == decomposed)
        let long = "downloads/" + String(repeating: "d", count: 500) + ".partial"
        #expect(ResumeEvidence(summary: "x", stagingPath: long).stagingPath == long)
        for refused in [
            "/Volumes/staging/restore.partial",
            "~/staging/restore.partial",
            "../../etc/passwd",
            "downloads//restore.partial",
            "downloads/./restore.partial",
            "downloads/\u{202E}restore.partial",
            "downloads/restore\npartial",
            "",
            String(repeating: "d", count: 2_000),
            "downloads/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab.partial",
        ] {
            #expect(ResumeEvidence(summary: "x", stagingPath: refused).stagingPath == nil, "\(refused.debugDescription)")
        }
    }
}
