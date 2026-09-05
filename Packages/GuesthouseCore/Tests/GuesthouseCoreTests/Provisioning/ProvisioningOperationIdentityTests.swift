import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningOperationIdentityTests {
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

    @Test func aStillRunningOperationResumesMonitoringUnderItsIdentity() throws {
        let resumed = try ProvisioningReducer.reduce(state(.unknownOutcome(operation, inspection: outstanding)), .operationReconciled(outstanding, operation, .stillRunning(stage: .first)))
        #expect(resumed.state.status == .inProgress(operation))
        #expect(resumed.effects.isEmpty)
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(resumed.state, .startRequested(stage: .first))
        }
    }

    @Test func connectionLossWhileAwaitingUserActionBecomesUnknown() throws {
        let lost = try ProvisioningReducer.reduce(state(.needsUserAction(operation, .loginExpired(.github))), .connectionInterrupted(operation))
        #expect(lost.state.status == .unknownOutcome(operation, inspection: try token(of: lost.effects)))
        #expect(lost.effects == [.inspectActualState(.first, try token(of: lost.effects), operation: operation)])
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
        #expect(second.effects == [.inspectActualState(.first, live, operation: nil)])
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
            try ProvisioningReducer.reduce(again.state, .operationReconciled(first, operation, .quiescent(.completed(checkpoint))))
        }
    }

    /// Inspecting from a live start request would release the reservation while the runtime can
    /// still accept it, so a `notStarted` verdict would let a second start race the first. The
    /// refusal used to be a plain illegal transition, whose `inspectState` recovery sends the
    /// very event that was just refused — a button that can only produce the same error again.
    @Test func inspectionIsRefusedWhileAStartRequestIsLiveAndSaysWhatWorksInstead() throws {
        #expect(throws: ProvisioningTransitionError.inspectionWhileStartRequestLive) {
            try ProvisioningReducer.reduce(state(.startRequested(request: outstanding, resuming: nil)), .inspectionRequested)
        }
        #expect(!ProvisioningTransitionError.inspectionWhileStartRequestLive.recoveryActions.contains(.inspectState))
        #expect(!ProvisioningTransitionError.inspectionWhileStartRequestLive.recoveryActions.isEmpty)
        // A request no longer in flight — the connection dropped, or the app was relaunched over
        // a saved reservation — is reported as interrupted, and that does inspect.
        let interrupted = try ProvisioningReducer.reduce(state(.startRequested(request: outstanding, resuming: nil)), .startRequestInterrupted(request: outstanding))
        #expect(interrupted.state.status.caseName == "awaitingInspection")
    }

    @Test func inspectionCanBeRequestedFromEveryOtherStatus() throws {
        for status in [StageStatus.notStarted, .completed(checkpoint), .recoverableFailure(.canceled, interrupted: nil), .startRejected(.canceled, resuming: nil), .cleanupRequired(.canceled, cleanup: outstanding), .persistingCheckpoint(checkpoint, operation: nil, write: outstanding), .awaitingInspection(outstanding)] {
            let result = try ProvisioningReducer.reduce(state(status), .inspectionRequested)
            let issued = try token(of: result.effects)
            #expect(result.state.status == .awaitingInspection(issued), "\(status.caseName)")
            #expect(result.effects == [.inspectActualState(.first, issued, operation: nil)], "\(status.caseName)")
        }
        // An unknown outcome keeps the interrupted operation's identity while it inspects again.
        let unknown = try ProvisioningReducer.reduce(state(.unknownOutcome(operation, inspection: outstanding)), .inspectionRequested)
        #expect(unknown.state.status == .unknownOutcome(operation, inspection: EffectToken(2)))
    }

    /// A live operation used to lose its identity the moment anything asked for an inspection,
    /// so reconciliation could adopt a different running operation, or call the stage not
    /// started, while the first one was still free to mutate.
    @Test func inspectionKeepsTheIdentityOfAnOperationThatIsStillLive() throws {
        let paused = StageStatus.needsUserAction(operation, .credentialsLocked(.guestKeychain))
        let live: [(StageStatus, ProvisioningEvent)] = [
            (.inProgress(operation), .inspectionRequested),
            (paused, .inspectionRequested),
            (paused, .userActionCompleted),
        ]
        for (status, event) in live {
            let result = try ProvisioningReducer.reduce(state(status), event)
            let issued = try token(of: result.effects)
            #expect(result.state.status == .unknownOutcome(operation, inspection: issued), "\(status.caseName)/\(event.caseName)")
            #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger), "\(status.caseName)/\(event.caseName)") {
                try ProvisioningReducer.reduce(result.state, .operationReconciled(issued, stranger, .stillRunning(stage: .first)))
            }
        }
    }

    /// An inspection that cannot be carried out used to have no callback at all, so the reason
    /// it failed — and the recovery actions that go with it — never reached the coordinator.
    @Test func aFailedInspectionKeepsItsErrorAndIsCorrelated() throws {
        let unreachable = GuesthouseError.guestNotReachable(EnvironmentID())
        // A failed check settles nothing, so the operation an interrupted status named is still
        // unaccounted for and travels with the failure; a status that never knew one still
        // does not.
        for (status, unaccountedFor) in [
            (StageStatus.awaitingInspection(outstanding), nil),
            (.unknownOutcome(operation, inspection: outstanding), operation),
        ] as [(StageStatus, OperationID?)] {
            #expect(throws: ProvisioningTransitionError.staleEffect(expected: outstanding, actual: EffectToken(9)), "\(status.caseName)") {
                try ProvisioningReducer.reduce(state(status), .inspectionFailed(EffectToken(9), unreachable))
            }
            let failed = try ProvisioningReducer.reduce(state(status), .inspectionFailed(outstanding, unreachable))
            #expect(failed.state.status == .recoverableFailure(unreachable, interrupted: unaccountedFor), "\(status.caseName)")
            #expect(failed.effects.isEmpty, "\(status.caseName)")
            guard case .recoverableFailure(let error, _) = failed.state.status else { Issue.record("expected recoverableFailure"); return }
            #expect(error.recoveryActions.contains(.inspectState))
            // Nothing may start off a failed check; the retry inspects again.
            #expect(throws: ProvisioningTransitionError.self, "\(status.caseName)") {
                try ProvisioningReducer.reduce(failed.state, .startRequested(stage: .first))
            }
            for event in [ProvisioningEvent.userRetried, .inspectionRequested] {
                let again = try ProvisioningReducer.reduce(failed.state, event)
                let token = try token(of: again.effects)
                #expect(again.effects == [.inspectActualState(.first, token, operation: unaccountedFor)], "\(status.caseName)")
                // The replacement inspection is scoped exactly as the failed one was.
                let expected = unaccountedFor.map { StageStatus.unknownOutcome($0, inspection: token) } ?? .awaitingInspection(token)
                #expect(again.state.status == expected, "\(status.caseName)")
            }
        }
    }

    /// A check that could not answer must not become permission to track a different operation:
    /// the first one may still be mutating, and only an inspection scoped to it can say so.
    @Test func aRetryAfterAFailedCheckStaysScopedToTheInterruptedOperation() throws {
        let interrupted = try ProvisioningReducer.reduce(state(.inProgress(operation)), .connectionInterrupted(operation))
        let failed = try ProvisioningReducer.reduce(interrupted.state, .inspectionFailed(try token(of: interrupted.effects), .guestNotReachable(EnvironmentID())))
        let retried = try ProvisioningReducer.reduce(failed.state, .userRetried)
        let replacement = try token(of: retried.effects)
        #expect(retried.state.status == .unknownOutcome(operation, inspection: replacement))
        let other = OperationID()
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: other)) {
            try ProvisioningReducer.reduce(retried.state, .operationReconciled(replacement, other, .stillRunning(stage: .first)))
        }
        #expect(try ProvisioningReducer.reduce(retried.state, .operationReconciled(replacement, operation, .stillRunning(stage: .first))).state.status == .inProgress(operation))
    }

    /// The partial artifact outlives a refused start, so the reservation and the refusal carry
    /// the evidence that names it; dropping it left the next start with nothing to resume from.
    @Test func resumeEvidenceSurvivesARejectedStart() throws {
        let evidence = ResumeEvidence(summary: "62% downloaded", stagingPath: "downloads/restore.ipsw.partial")
        let reserved = try ProvisioningReducer.reduce(state(.resumable(evidence)), .startRequested(stage: .first))
        let request = try #require(reserved.state.status.pendingEffect)
        #expect(reserved.state.status == .startRequested(request: request, resuming: evidence))
        let rejected = try ProvisioningReducer.reduce(reserved.state, .startRequestRejected(.canceled, request: request))
        #expect(rejected.state.status == .startRejected(.canceled, resuming: evidence))
        let again = try ProvisioningReducer.reduce(rejected.state, .startRequested(stage: .first))
        let nextRequest = try #require(again.state.status.pendingEffect)
        #expect(nextRequest != request)
        #expect(again.state.status == .startRequested(request: nextRequest, resuming: evidence))
        // The evidence survives a relaunch between the refusal and the next attempt.
        let relaunched = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(rejected.state))
        #expect(relaunched.status == .startRejected(.canceled, resuming: evidence))
        // A start that never had evidence still carries none.
        #expect(try ProvisioningReducer.reduce(state(.notStarted), .startRequested(stage: .first)).state.status == .startRequested(request: outstanding, resuming: nil))
    }

    /// A can answer after inspection has settled its interruption and B has been reserved.
    /// Even A's wrong-stage acceptance must check its request identity before releasing B.
    @Test(arguments: [
        ProvisioningEvent.operationStarted(OperationID(), stage: .first, request: EffectToken(1)),
        .operationStarted(OperationID(), stage: .ready, request: EffectToken(1)),
        .startRequestRejected(.canceled, request: EffectToken(1)),
        .startRequestInterrupted(request: EffectToken(1)),
    ])
    func aStaleStartReplyCannotSettleANewerReservation(reply: ProvisioningEvent) throws {
        let first = try ProvisioningReducer.reduce(.initial, .startRequested(stage: .first)).state
        let interrupted = try ProvisioningReducer.reduce(first, .startRequestInterrupted(request: outstanding))
        let inspected = try ProvisioningReducer.reduce(interrupted.state, .reconciled(try token(of: interrupted.effects), .notStarted)).state
        let second = try ProvisioningReducer.reduce(inspected, .startRequested(stage: .first)).state
        let live = try #require(second.status.pendingEffect)
        #expect(live == EffectToken(3))
        #expect(throws: ProvisioningTransitionError.staleStartRequest(expected: live, actual: outstanding)) {
            try ProvisioningReducer.reduce(second, reply)
        }
        #expect(throws: ProvisioningTransitionError.inspectionWhileStartRequestLive) {
            try ProvisioningReducer.reduce(second, .inspectionRequested)
        }
        #expect(try ProvisioningReducer.reduce(second, .operationStarted(operation, stage: .first, request: live)).state.status == .inProgress(operation))
    }

    @Test func startRequestIdentityAndResumeEvidenceSurviveRelaunch() throws {
        let evidence = ResumeEvidence(summary: "62% downloaded", stagingPath: "downloads/restore.ipsw.partial")
        let first = try ProvisioningReducer.reduce(state(.resumable(evidence)), .startRequested(stage: .first)).state
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(first))
        #expect(restored == first)
        let firstRequest = try #require(restored.status.pendingEffect)
        let refused = try ProvisioningReducer.reduce(restored, .startRequestRejected(.canceled, request: firstRequest)).state
        let second = try ProvisioningReducer.reduce(refused, .startRequested(stage: .first)).state
        let restoredAgain = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(second))
        let secondRequest = try #require(restoredAgain.status.pendingEffect)
        #expect(secondRequest == EffectToken(firstRequest.value + 1))
        #expect(restoredAgain.status == .startRequested(request: secondRequest, resuming: evidence))
        #expect(throws: ProvisioningTransitionError.staleStartRequest(expected: secondRequest, actual: firstRequest)) {
            try ProvisioningReducer.reduce(restoredAgain, .startRequestRejected(.canceled, request: firstRequest))
        }
        let interrupted = try ProvisioningReducer.reduce(restoredAgain, .startRequestInterrupted(request: secondRequest))
        #expect(try token(of: interrupted.effects) == EffectToken(secondRequest.value + 1))
    }

    @Test(arguments: [ProvisioningStage.runtimeReady, .ready])
    func wrongStageAcceptanceInspectsAndKeepsItsOperationThroughRecovery(reportedStage: ProvisioningStage) throws {
        let reserved = try ProvisioningReducer.reduce(.initial, .startRequested(stage: .first)).state
        let request = try #require(reserved.status.pendingEffect)
        let accepted = try ProvisioningReducer.reduce(reserved, .operationStarted(operation, stage: reportedStage, request: request))
        let inspection = try token(of: accepted.effects)
        #expect(accepted.state.stage == .first)
        #expect(accepted.state.status == .unknownOutcome(operation, inspection: inspection))
        #expect(accepted.effects == [.inspectActualState(.first, inspection, operation: operation)])
        #expect(inspection.value > request.value)
        #expect(throws: ProvisioningTransitionError.illegalTransition(status: "unknownOutcome", event: "reconciled")) {
            try ProvisioningReducer.reduce(accepted.state, .reconciled(inspection, .notStarted))
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(accepted.state, .startRequested(stage: .first))
        }
        #expect(try ProvisioningReducer.reduce(accepted.state, .operationReconciled(inspection, operation, .stillRunning(stage: reportedStage))).state.status == .inProgress(operation))
        let failed = try ProvisioningReducer.reduce(accepted.state, .inspectionFailed(inspection, .runtimeMissing)).state
        #expect(failed.status == .recoverableFailure(.runtimeMissing, interrupted: operation))
        let relaunched = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(accepted.state))
        for event in [ProvisioningEvent.inspectionRequested, .userRetried] {
            // Both direct recovery and recovery after a failed inspection must stay scoped.
            for recoverable in [accepted.state, failed, relaunched] {
                let retried = try ProvisioningReducer.reduce(recoverable, event)
                let retry = try token(of: retried.effects)
                #expect(retried.state.status == .unknownOutcome(operation, inspection: retry))
                #expect(retried.effects == [.inspectActualState(.first, retry, operation: operation)])
                #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
                    try ProvisioningReducer.reduce(retried.state, .operationReconciled(retry, stranger, .stillRunning(stage: reportedStage)))
                }
                #expect(try ProvisioningReducer.reduce(retried.state, .operationReconciled(retry, operation, .stillRunning(stage: reportedStage))).state.status == .inProgress(operation))
            }
        }
    }

    /// The acceptance's stage is untrusted until inspection confirms the same operation there.
    /// Once confirmed, its checkpoint must be recorded at that actual stage, even if it is earlier.
    @Test(arguments: [ProvisioningStage.runtimeReady, .guestSecured], [false, true])
    func confirmedActiveOperationAdoptsItsActualStageBeforeCheckpoint(actualStage: ProvisioningStage, paused: Bool) throws {
        let reservedStage = ProvisioningStage.macOSInstalled
        let initial = ProvisioningState(stage: reservedStage, status: .notStarted)
        let reserved = try ProvisioningReducer.reduce(initial, .startRequested(stage: reservedStage)).state
        let accepted = try ProvisioningReducer.reduce(reserved, .operationStarted(operation, stage: actualStage, request: #require(reserved.status.pendingEffect)))
        let oldInspection = try token(of: accepted.effects)
        #expect(accepted.state.stage == reservedStage)
        let inspecting = try ProvisioningReducer.reduce(accepted.state, .inspectionRequested)
        let inspection = try token(of: inspecting.effects)
        #expect(inspecting.state.stage == reservedStage)
        #expect(inspecting.effects == [.inspectActualState(reservedStage, inspection, operation: operation)])
        let error = GuesthouseError.credentialsLocked(.guestKeychain)
        let outcome: OperationInspectionOutcome = paused ? .stillNeedsUserAction(error, stage: actualStage) : .stillRunning(stage: actualStage)
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: inspection, actual: oldInspection)) {
            try ProvisioningReducer.reduce(inspecting.state, .operationReconciled(oldInspection, operation, outcome))
        }
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
            try ProvisioningReducer.reduce(inspecting.state, .operationReconciled(inspection, stranger, outcome))
        }
        let active = try ProvisioningReducer.reduce(inspecting.state, .operationReconciled(inspection, operation, outcome)).state
        #expect(active.stage == actualStage)
        #expect(active.status == (paused ? .needsUserAction(operation, error) : .inProgress(operation)))
        let reachedCheckpoint = Checkpoint(stage: actualStage, reachedAt: checkpoint.reachedAt)
        let reached = try ProvisioningReducer.reduce(active, .checkpointReached(operation, reachedCheckpoint))
        let write = try token(of: reached.effects)
        #expect(reached.state.status == .persistingCheckpoint(reachedCheckpoint, operation: operation, write: write))
        let persisted = try ProvisioningReducer.reduce(reached.state, .checkpointPersisted(write, reachedCheckpoint)).state
        #expect(persisted.stage == actualStage)
        #expect(persisted.status == .completed(reachedCheckpoint))
    }

    @Test(arguments: [
        OperationInspectionOutcome.stillRunning(stage: .first),
        .stillNeedsUserAction(.credentialsLocked(.guestKeychain), stage: .first),
        .quiescent(.notStarted),
    ])
    func operationInspectionRepliesRequireBothCurrentTokenAndOperation(outcome: OperationInspectionOutcome) throws {
        let original = state(.unknownOutcome(operation, inspection: outstanding))
        let renewed = try ProvisioningReducer.reduce(original, .inspectionRequested)
        let inspection = try token(of: renewed.effects)
        #expect(renewed.effects == [.inspectActualState(.first, inspection, operation: operation)])
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: inspection, actual: outstanding)) {
            try ProvisioningReducer.reduce(renewed.state, .operationReconciled(outstanding, operation, outcome))
        }
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
            try ProvisioningReducer.reduce(renewed.state, .operationReconciled(inspection, stranger, outcome))
        }
        let current = try ProvisioningReducer.reduce(renewed.state, .operationReconciled(inspection, operation, outcome)).state
        switch outcome {
        case .quiescent:
            #expect(current.status == .notStarted)
            #expect(try ProvisioningReducer.reduce(current, .startRequested(stage: .first)).state.status.caseName == "startRequested")
        case .stillRunning, .stillNeedsUserAction:
            #expect(throws: ProvisioningTransitionError.self) {
                try ProvisioningReducer.reduce(current, .startRequested(stage: .first))
            }
            let rechecked = try ProvisioningReducer.reduce(current, .inspectionRequested)
            #expect(rechecked.effects == [.inspectActualState(.first, try token(of: rechecked.effects), operation: operation)])
        }
    }

    @Test func aQuiescentOperationCannotAlsoBeReportedActive() {
        let inspecting = state(.unknownOutcome(operation, inspection: outstanding))
        for active in [ReconciledOutcome.stillRunning(operation), .stillNeedsUserAction(operation, .credentialsLocked(.guestKeychain))] {
            #expect(throws: ProvisioningTransitionError.illegalTransition(status: "unknownOutcome", event: "operationReconciled")) {
                try ProvisioningReducer.reduce(inspecting, .operationReconciled(outstanding, operation, .quiescent(active)))
            }
        }
    }

    @Test func aSeparateCleanupKeepsRestartBlockedAfterTheOperationIsQuiescent() throws {
        let inspecting = state(.unknownOutcome(operation, inspection: outstanding))
        let cleanup = EffectToken(7)
        let continued = try ProvisioningReducer.reduce(inspecting, .operationReconciled(outstanding, operation, .quiescent(.cleanupRunning(cleanup, .canceled))))
        #expect(continued.state.status == .cleanupRequired(.canceled, cleanup: cleanup))
        #expect(continued.effects.isEmpty)
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(continued.state, .startRequested(stage: .first))
        }
        let finished = try ProvisioningReducer.reduce(continued.state, .cleanupFinished(cleanup)).state
        #expect(try ProvisioningReducer.reduce(finished, .startRequested(stage: .first)).state.status == .startRequested(request: EffectToken(8), resuming: nil))
    }

    /// Fixture: the reserved preflight stage has not started, but this operation is running at
    /// runtimeReady. Looking only at preflight would falsely permit a second start.
    @Test func inspectionFindsTheNamedOperationOutsideTheReservedStage() throws {
        let requested = try ProvisioningReducer.reduce(.initial, .startRequested(stage: .first)).state
        let accepted = try ProvisioningReducer.reduce(requested, .operationStarted(operation, stage: .runtimeReady, request: #require(requested.status.pendingEffect)))
        var runningByStage: [ProvisioningStage: OperationID] = [.runtimeReady: operation]
        let effect = try #require(accepted.effects.first)
        guard case .inspectActualState(let reservedStage, let inspection, let target) = effect else { Issue.record("expected inspection"); return }
        #expect(reservedStage == .preflight)
        let targetOperation = try #require(target)
        #expect(targetOperation == operation)
        #expect(runningByStage[reservedStage] == nil)
        let found = try #require(runningByStage.first { $0.value == targetOperation })
        #expect(found.key == .runtimeReady)
        let monitored = try ProvisioningReducer.reduce(accepted.state, .operationReconciled(inspection, targetOperation, .stillRunning(stage: found.key))).state
        #expect(monitored.stage == .runtimeReady)
        #expect(monitored.status == .inProgress(operation))
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(monitored, .startRequested(stage: .runtimeReady))
        }
        let stoppedCheck = try ProvisioningReducer.reduce(monitored, .inspectionRequested)
        #expect(stoppedCheck.effects == [.inspectActualState(.runtimeReady, try token(of: stoppedCheck.effects), operation: operation)])
        // The fixture reports quiescence only after the named operation has stopped everywhere.
        runningByStage.removeValue(forKey: .runtimeReady)
        #expect(!runningByStage.values.contains(operation))
        let quiescent = try ProvisioningReducer.reduce(stoppedCheck.state, .operationReconciled(try token(of: stoppedCheck.effects), operation, .quiescent(.notStarted))).state
        #expect(try ProvisioningReducer.reduce(quiescent, .startRequested(stage: .runtimeReady)).state.status.caseName == "startRequested")
    }

    /// These are the schema-1 shapes written before start requests carried a token: nil
    /// associated values were omitted, and a resumable reservation carried only `resuming`.
    @Test(arguments: [
        #"{"schemaVersion":1,"stage":"preflight","issuedEffects":9,"status":{"startRequested":{}}}"#,
        #"{"schemaVersion":1,"stage":"preflight","issuedEffects":9,"status":{"startRequested":{"resuming":{"summary":"62% downloaded","stagingPath":"downloads/restore.ipsw.partial"}}}}"#,
    ])
    func legacyStartReservationsCanOnlyRecoverThroughInspection(record: String) throws {
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: Data(record.utf8))
        guard case .startRequested(let request, let evidence) = restored.status else { Issue.record("expected saved reservation"); return }
        #expect(request == nil)
        #expect(restored.issuedEffects == 9)
        if record.contains("resuming") {
            #expect(evidence == ResumeEvidence(summary: "62% downloaded", stagingPath: "downloads/restore.ipsw.partial"))
        } else {
            #expect(evidence == nil)
        }
        for reply in [
            ProvisioningEvent.operationStarted(operation, stage: .first, request: outstanding),
            .operationStarted(operation, stage: .ready, request: outstanding),
            .startRequestRejected(.canceled, request: outstanding),
            .startRequestInterrupted(request: outstanding),
        ] {
            #expect(throws: ProvisioningTransitionError.illegalTransition(status: "startRequested", event: reply.caseName)) {
                try ProvisioningReducer.reduce(restored, reply)
            }
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(restored, .startRequested(stage: .first))
        }
        let inspecting = try ProvisioningReducer.reduce(restored, .inspectionRequested)
        #expect(inspecting.state.status == .awaitingInspection(EffectToken(10)))
        #expect(inspecting.effects == [.inspectActualState(.first, EffectToken(10), operation: nil)])
        let inspected = try ProvisioningReducer.reduce(inspecting.state, .reconciled(EffectToken(10), .notStarted)).state
        #expect(try ProvisioningReducer.reduce(inspected, .startRequested(stage: .first)).state.status == .startRequested(request: EffectToken(11), resuming: nil))
    }

    @Test func startRequestTokensAdvanceThePersistedCounter() throws {
        let record = Data(#"{"schemaVersion":1,"stage":"preflight","issuedEffects":0,"status":{"startRequested":{"request":9}}}"#.utf8)
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: record)
        #expect(restored.issuedEffects == 9)
        #expect(restored.status.pendingEffect == EffectToken(9))
        let interrupted = try ProvisioningReducer.reduce(restored, .startRequestInterrupted(request: EffectToken(9)))
        #expect(try token(of: interrupted.effects) == EffectToken(10))
    }

    /// An operation paused at the guest console is still paused when contact comes back. Calling
    /// it "running" would hide the prompt and its recovery actions.
    @Test func aPausedOperationStaysPausedAfterReconciliation() throws {
        let paused = GuesthouseError.credentialsLocked(.guestKeychain)
        let lost = try ProvisioningReducer.reduce(state(.needsUserAction(operation, paused)), .connectionInterrupted(operation))
        let inspection = try token(of: lost.effects)
        let restored = try ProvisioningReducer.reduce(lost.state, .operationReconciled(inspection, operation, .stillNeedsUserAction(paused, stage: .first)))
        #expect(restored.state.status == .needsUserAction(operation, paused))
        #expect(restored.effects.isEmpty)
        guard case .needsUserAction(_, let error) = restored.state.status else { Issue.record("expected needsUserAction"); return }
        #expect(error.recoveryActions.contains(.openConsole))
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
            try ProvisioningReducer.reduce(lost.state, .operationReconciled(inspection, stranger, .stillNeedsUserAction(paused, stage: .first)))
        }
        // The user can still report the step done, and that inspects under the same identity.
        #expect(try ProvisioningReducer.reduce(restored.state, .userActionCompleted).state.status.caseName == "unknownOutcome")
    }

    /// `stillRunning` describes the interrupted operation itself. Adopting a different identity
    /// would leave the original free to keep mutating with its callbacks rejected as mismatches.
    @Test func aReconciledRunningOperationMustBeTheInterruptedOne() throws {
        let lost = try ProvisioningReducer.reduce(state(.inProgress(operation)), .connectionInterrupted(operation))
        let inspection = try token(of: lost.effects)
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: stranger)) {
            try ProvisioningReducer.reduce(lost.state, .operationReconciled(inspection, stranger, .stillRunning(stage: .first)))
        }
        // Inspection after a relaunch knows no identity, so the reported one is the only one.
        let adopted = try ProvisioningReducer.reduce(state(.awaitingInspection(outstanding)), .reconciled(outstanding, .stillRunning(stranger)))
        #expect(adopted.state.status == .inProgress(stranger))
    }
}
