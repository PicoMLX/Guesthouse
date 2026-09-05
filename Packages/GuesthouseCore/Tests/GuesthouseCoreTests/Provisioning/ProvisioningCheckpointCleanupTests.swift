import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningCheckpointCleanupTests {
    let operation = OperationID()
    let stranger = OperationID()
    let checkpoint = Checkpoint(stage: .first, reachedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let outstanding = EffectToken(1)

    func state(_ status: StageStatus) -> ProvisioningState { ProvisioningState(stage: .first, status: status) }

    /// The token the reducer stamped on the effect it just asked for; the coordinator echoes it
    /// back in the callback, and so do these tests.
    func token(of effects: [ProvisioningEffect]) throws -> EffectToken {
        switch try #require(effects.first) {
        case .inspectActualState(_, let token, _), .persistCheckpoint(_, let token), .cleanUp(_, let token): token
        }
    }

    @Test func aFailedCheckpointWriteIsAFailureWithRecoveryNotALoop() throws {
        let failed = try ProvisioningReducer.reduce(state(.persistingCheckpoint(checkpoint, operation: operation, write: outstanding)), .checkpointPersistenceFailed(outstanding, .insufficientDisk(requiredBytes: 2, availableBytes: 1, volumePath: "/")))
        #expect(failed.effects.isEmpty)
        guard case .recoverableFailure(let error, _) = failed.state.status else { Issue.record("expected recoverableFailure"); return }
        #expect(error.recoveryActions.contains(.freeDiskSpace))
        let retried = try ProvisioningReducer.reduce(failed.state, .userRetried)
        let persisted = try ProvisioningReducer.reduce(retried.state, .operationReconciled(try token(of: retried.effects), operation, .quiescent(.completed(checkpoint))))
        #expect(persisted.effects == [.persistCheckpoint(checkpoint, try token(of: persisted.effects))])
    }

    /// A failed journal write settles the write, not the operation that reached its checkpoint.
    /// Its identity survives either recovery route until inspection establishes quiescence.
    @Test(arguments: [ProvisioningEvent.userRetried, .inspectionRequested])
    func checkpointWriteFailurePreservesItsWriterDuringRecovery(recovery: ProvisioningEvent) throws {
        let error = GuesthouseError.insufficientDisk(requiredBytes: 2, availableBytes: 1, volumePath: "/")
        for writer in [Optional(operation), nil] {
            let writing = state(.persistingCheckpoint(checkpoint, operation: writer, write: outstanding))
            let failed = try ProvisioningReducer.reduce(writing, .checkpointPersistenceFailed(outstanding, error))
            #expect(failed.state.status == .recoverableFailure(error, interrupted: writer))
            #expect(failed.effects.isEmpty)
            let restored = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(failed.state))
            let inspected = try ProvisioningReducer.reduce(restored, recovery)
            let inspection = try token(of: inspected.effects)
            #expect(inspected.effects == [.inspectActualState(.first, inspection, operation: writer)])
            if let writer {
                #expect(inspected.state.status == .unknownOutcome(writer, inspection: inspection))
                #expect(throws: ProvisioningTransitionError.operationMismatch(expected: writer, actual: stranger)) {
                    try ProvisioningReducer.reduce(inspected.state, .operationReconciled(inspection, stranger, .stillRunning(stage: .first)))
                }
                #expect(try ProvisioningReducer.reduce(inspected.state, .operationReconciled(inspection, writer, .stillRunning(stage: .first))).state.status == .inProgress(writer))
            } else {
                #expect(inspected.state.status == .awaitingInspection(inspection))
                #expect(try ProvisioningReducer.reduce(inspected.state, .reconciled(inspection, .stillRunning(stranger))).state.status == .inProgress(stranger))
            }
            let completed: ProvisioningEvent = writer.map { .operationReconciled(inspection, $0, .quiescent(.completed(checkpoint))) } ?? .reconciled(inspection, .completed(checkpoint))
            let rewritten = try ProvisioningReducer.reduce(inspected.state, completed)
            let replacement = try token(of: rewritten.effects)
            #expect(rewritten.state.status == .persistingCheckpoint(checkpoint, operation: nil, write: replacement))
            #expect(throws: ProvisioningTransitionError.staleEffect(expected: replacement, actual: outstanding)) {
                try ProvisioningReducer.reduce(rewritten.state, .checkpointPersistenceFailed(outstanding, .canceled))
            }
            #expect(try ProvisioningReducer.reduce(rewritten.state, .checkpointPersisted(replacement, checkpoint)).state.status == .completed(checkpoint))
        }
    }

    @Test func interruptedCheckpointWritesAndCleanupsAreInspected() throws {
        // The operation that reached the checkpoint keeps its identity through the check: it
        // may still be mutating, and an unscoped inspection would adopt a status naming a
        // different operation without checking.
        let write = try ProvisioningReducer.reduce(state(.persistingCheckpoint(checkpoint, operation: operation, write: outstanding)), .connectionInterrupted(operation))
        #expect(write.state.status == .unknownOutcome(operation, inspection: try token(of: write.effects)))
        #expect(write.effects == [.inspectActualState(.first, try token(of: write.effects), operation: operation)])
        // A cleanup is an effect, not an operation, so an interruption naming an operation is
        // never about it; the cleanup's token would otherwise be replaced by a late callback
        // belonging to something else, and its own `cleanupFinished` would arrive stale.
        #expect(throws: ProvisioningTransitionError.illegalTransition(status: "cleanupRequired", event: "connectionInterrupted")) {
            try ProvisioningReducer.reduce(state(.cleanupRequired(.canceled, cleanup: outstanding)), .connectionInterrupted(operation))
        }
        let cleanup = try ProvisioningReducer.reduce(state(.cleanupRequired(.canceled, cleanup: outstanding)), .inspectionRequested)
        #expect(cleanup.state.status.caseName == "awaitingInspection")
        let cleanupRetry = try ProvisioningReducer.reduce(state(.cleanupRequired(.canceled, cleanup: outstanding)), .userRetried)
        #expect(cleanupRetry.effects == [.inspectActualState(.first, try token(of: cleanupRetry.effects), operation: nil)])
    }

    /// A paused operation is still alive: it can die with the guest, and it can resume and reach
    /// its checkpoint before the GUI reports the out-of-app step done.
    @Test func aPausedOperationCanStillFailOrReachItsCheckpoint() throws {
        let paused = state(.needsUserAction(operation, .credentialsLocked(.guestKeychain)))
        let gone = GuesthouseError.guestNotReachable(EnvironmentID())
        let died = try ProvisioningReducer.reduce(paused, .operationFailed(operation, gone))
        #expect(died.state.status == .recoverableFailure(gone, interrupted: nil))
        #expect(died.effects.isEmpty)
        let reached = try ProvisioningReducer.reduce(paused, .checkpointReached(operation, checkpoint))
        #expect(reached.state.status == .persistingCheckpoint(checkpoint, operation: operation, write: try token(of: reached.effects)))
        #expect(reached.effects == [.persistCheckpoint(checkpoint, try token(of: reached.effects))])
        // Both still belong to the paused operation and nobody else's.
        for event in [ProvisioningEvent.operationFailed(stranger, .canceled), .checkpointReached(stranger, checkpoint)] {
            #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger), "\(event.caseName)") {
                try ProvisioningReducer.reduce(paused, event)
            }
        }
    }

    /// A write reconciliation started belongs to no operation, so an operation-scoped
    /// interruption says nothing about it. Treating the missing writer as a wildcard abandoned
    /// a live write and made its own successful callback stale.
    @Test func anUncorrelatedInterruptionCannotAbandonAReconciledWrite() throws {
        let reconciled = try ProvisioningReducer.reduce(state(.awaitingInspection(outstanding)), .reconciled(outstanding, .completed(checkpoint)))
        let write = try token(of: reconciled.effects)
        #expect(throws: ProvisioningTransitionError.illegalTransition(status: "persistingCheckpoint", event: "connectionInterrupted")) {
            try ProvisioningReducer.reduce(reconciled.state, .connectionInterrupted(operation))
        }
        #expect(try ProvisioningReducer.reduce(reconciled.state, .checkpointPersisted(write, checkpoint)).state.status == .completed(checkpoint))
        // The write's own uncertainty still has a way out that does not depend on an operation.
        #expect(try ProvisioningReducer.reduce(reconciled.state, .userRetried).state.status.caseName == "awaitingInspection")
    }

    /// A record naming a counter at the end of the range would make the next token mint overflow
    /// and trap the process rather than being reported as the corrupt record it is.
    @Test func anExhaustedEffectCounterIsRefusedWhenDecoded() throws {
        func record(_ issued: String, status: String = "{\"notStarted\":{}}") -> Data {
            Data("{\"schemaVersion\":1,\"stage\":\"preflight\",\"issuedEffects\":\(issued),\"status\":\(status)}".utf8)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ProvisioningState.self, from: record("18446744073709551615")) }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProvisioningState.self, from: record("0", status: "{\"awaitingInspection\":{\"_0\":18446744073709551615}}"))
        }
        let accepted = try JSONDecoder().decode(ProvisioningState.self, from: record("\(ProvisioningState.maximumIssuedEffects)"))
        #expect(accepted.issuedEffects == ProvisioningState.maximumIssuedEffects)
        // The ceiling bounds what a record may say, not what a live state may hold: the first
        // transition after reading one at the ceiling mints a token above it, and that has to
        // produce a state rather than trap the process on the way out of a bad record.
        let minted = try ProvisioningReducer.reduce(accepted, .inspectionRequested)
        #expect(minted.state.issuedEffects == ProvisioningState.maximumIssuedEffects + 1)
        #expect(minted.state.status == .awaitingInspection(EffectToken(ProvisioningState.maximumIssuedEffects + 1)))
    }

    /// A cleanup whose connection dropped can be reported as finished long after a second
    /// cleanup was launched; accepting it would allow a start against the second one's leftovers.
    @Test func aStaleCleanupCallbackCannotClearANewerCleanup() throws {
        let first = try ProvisioningReducer.reduce(state(.awaitingInspection(outstanding)), .reconciled(outstanding, .failedNeedsCleanup(.canceled)))
        let abandoned = try token(of: first.effects)
        let interrupted = try ProvisioningReducer.reduce(first.state, .inspectionRequested)
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

    /// A delayed failure from an abandoned write used to be accepted as the failure of the write
    /// that replaced it, leaving an obsolete persistence error over a durable checkpoint.
    @Test func aStaleCheckpointWriteFailureCannotOverwriteANewerWrite() throws {
        let reached = try ProvisioningReducer.reduce(state(.inProgress(operation)), .checkpointReached(operation, checkpoint))
        let abandoned = try token(of: reached.effects)
        let interrupted = try ProvisioningReducer.reduce(reached.state, .connectionInterrupted(operation))
        let rewritten = try ProvisioningReducer.reduce(interrupted.state, .operationReconciled(try token(of: interrupted.effects), operation, .quiescent(.completed(checkpoint))))
        let live = try token(of: rewritten.effects)
        #expect(live != abandoned)
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: live, actual: abandoned)) {
            try ProvisioningReducer.reduce(rewritten.state, .checkpointPersistenceFailed(abandoned, .canceled))
        }
        #expect(try ProvisioningReducer.reduce(rewritten.state, .checkpointPersisted(live, checkpoint)).state.status == .completed(checkpoint))
    }

    /// A cleanup that is still running must be monitored, not repeated: a second cleanup would
    /// race the first over the same staging data, and `notStarted` would let provisioning start
    /// while the first cleanup can still remove what it produces.
    @Test func aCleanupThatIsStillRunningIsMonitoredNotDuplicated() throws {
        let requested = try ProvisioningReducer.reduce(state(.awaitingInspection(outstanding)), .reconciled(outstanding, .failedNeedsCleanup(.canceled)))
        let cleanup = try token(of: requested.effects)
        let interrupted = try ProvisioningReducer.reduce(requested.state, .inspectionRequested)
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
        let interrupted = try ProvisioningReducer.reduce(reached.state, .connectionInterrupted(operation))
        #expect(interrupted.state.status == .unknownOutcome(operation, inspection: try token(of: interrupted.effects)))
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

    /// A path keeps its spaces and its marks, so a credential split by one is a credential the
    /// detection probe has to reassemble before it decides — otherwise the token is journaled
    /// verbatim, which is exactly what redaction exists to prevent.
    @Test func aCredentialSplitByASpaceOrAMarkInAStagingPathIsRefused() {
        for refused in [
            "downloads/ghp_ABCDEFGHIJ KLMNOPQRSTUVWXYZ0123456789ab.partial",
            "downloads/ghp_ABC\u{0301}DEFGHIJKLMNOPQRSTUVWXYZ0123456789ab.partial",
            "downloads/ghp_ABCDEFGHIJ\u{00A0}KLMNOPQRSTUVWXYZ0123456789ab.partial",
            "downloads/sk-ABCDEFGH IJKLMNOPQRSTUV.partial",
        ] {
            #expect(ResumeEvidence(summary: "x", stagingPath: refused).stagingPath == nil, "\(refused.debugDescription)")
        }
        // The probe is not the path: ordinary names that merely contain spaces and marks are
        // still kept scalar for scalar.
        for kept in ["downloads/My Restore Images/Cafe\u{0301} 62%.ipsw.partial", "staging/a b c"] {
            #expect(ResumeEvidence(summary: "x", stagingPath: kept).stagingPath == kept, "\(kept.debugDescription)")
        }
    }

    /// The probe rewrites `/` and `.` into spaces, which is what makes a credential used as a
    /// file name visible — and what destroys the rules that need those characters. A path is
    /// measured in both readings, so neither rewriting can hide a credential from the other.
    @Test func aCredentialThatNeedsItsSeparatorsInAStagingPathIsRefused() {
        for refused in [
            // The escaped spelling passes the component checks that reject `https://`, whose
            // doubled slash leaves an empty component.
            "downloads/https:\\/\\/user:password@host/restore.partial",
            "downloads/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl",
        ] {
            #expect(ResumeEvidence(summary: "x", stagingPath: refused).stagingPath == nil, "\(refused.debugDescription)")
        }
        // A dotted name that is not a token still keeps every scalar it came with.
        let kept = "downloads/restore.ipsw.partial"
        #expect(ResumeEvidence(summary: "x", stagingPath: kept).stagingPath == kept)
    }

    @Test(arguments: [
        "downloads/eyJhbGciOiJIUzI1NiJ9.\u{0301}eyJzdWIiOiIxIn0.c2lnbmF0dXJl",
        "downloads/eyJhbGciOiJIUzI1NiJ9. eyJzdWIiOiIxIn0.c2lnbmF0dXJl",
        "downloads/https:\\\u{0301}/\\\u{0301}/user:password@host/restore.partial",
    ])
    func normalizedCredentialsKeepTheirSeparatorsForDetection(path: String) {
        #expect(ResumeEvidence(summary: "partial download", stagingPath: path).stagingPath == nil)
    }

    /// A checkpoint write restored after a relaunch has lost its effect but not the operation
    /// that reached the checkpoint. Retrying the check must keep that identity, or the reducer
    /// adopts whatever the inspection names and leaves the first operation unaccounted for.
    @Test(arguments: [ProvisioningEvent.userRetried, .inspectionRequested])
    func aRestoredCheckpointWriteKeepsItsOperationThroughInspection(request: ProvisioningEvent) throws {
        let restored = state(.persistingCheckpoint(checkpoint, operation: operation, write: outstanding))
        let retried = try ProvisioningReducer.reduce(restored, request)
        #expect(retried.state.status == .unknownOutcome(operation, inspection: try token(of: retried.effects)))
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
            try ProvisioningReducer.reduce(retried.state, .operationReconciled(try token(of: retried.effects), stranger, .stillRunning(stage: .first)))
        }
        #expect(try ProvisioningReducer.reduce(retried.state, .operationReconciled(try token(of: retried.effects), operation, .stillRunning(stage: .first))).state.status == .inProgress(operation))
        // A write reconciliation started has no operation behind it, and still inspects unscoped.
        let reconciled = try ProvisioningReducer.reduce(state(.persistingCheckpoint(checkpoint, operation: nil, write: outstanding)), request)
        #expect(reconciled.state.status.caseName == "awaitingInspection")
    }
}
