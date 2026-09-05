import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningStageTests {
    @Test func stagesFollowThePlanOrder() {
        #expect(ProvisioningStage.allCases.map(\.rawValue) == [
            "preflight", "runtimeReady", "macOSInstalled", "needsGuestSetup", "sshPaired",
            "guestSecured", "xcodeToolsReady", "accountsReady", "workspaceValidated", "ready",
        ])
        #expect(ProvisioningStage.first == .preflight)
        #expect(ProvisioningStage.preflight.next == .runtimeReady)
        #expect(ProvisioningStage.ready.next == nil)
        #expect(ProvisioningStage.preflight < ProvisioningStage.ready)
    }
}

@Suite struct ProvisioningReducerTests {
    typealias Reducer = ProvisioningReducer

    let op = OperationID()
    let other = OperationID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let failure = GuesthouseError.guestNotReachable(EnvironmentID())
    let consoleNeeded = GuesthouseError.credentialsLocked(.guestKeychain)
    let evidence = ResumeEvidence(summary: "restore image 62% downloaded", stagingPath: "downloads/restore.ipsw.partial")
    let pending = EffectToken(1)
    let next = EffectToken(2)

    func checkpoint(_ stage: ProvisioningStage) -> Checkpoint { Checkpoint(stage: stage, reachedAt: now) }
    func state(_ stage: ProvisioningStage, _ status: StageStatus) -> ProvisioningState { ProvisioningState(stage: stage, status: status) }

    /// The token the reducer stamped on the effect it just asked for. The coordinator echoes it
    /// in the callback, and so do these tests.
    func token(of effects: [ProvisioningEffect]) throws -> EffectToken {
        switch try #require(effects.first) {
        case .inspectActualState(_, let token, _), .persistCheckpoint(_, let token), .cleanUp(_, let token): token
        }
    }

    struct LegalTransition {
        let name: String
        let from: ProvisioningState
        let event: ProvisioningEvent
        let expectedStatus: String
        let expectedEffects: [ProvisioningEffect]
    }

    var legalTransitions: [LegalTransition] {
        [
            .init(name: "request first stage", from: .initial, event: .startRequested(stage: .preflight), expectedStatus: "startRequested", expectedEffects: []),
            .init(name: "runtime accepts the requested start", from: state(.preflight, .startRequested(request: pending, resuming: nil)), event: .operationStarted(op, stage: .preflight, request: pending), expectedStatus: "inProgress", expectedEffects: []),
            .init(name: "runtime rejects the request: error kept, nothing ran", from: state(.preflight, .startRequested(request: pending, resuming: nil)), event: .startRequestRejected(failure, request: pending), expectedStatus: "startRejected", expectedEffects: []),
            .init(name: "a new request after a rejection needs no inspection", from: state(.preflight, .startRejected(failure, resuming: nil)), event: .startRequested(stage: .preflight), expectedStatus: "startRequested", expectedEffects: []),
            .init(name: "user cancels while a console step is pending", from: state(.needsGuestSetup, .needsUserAction(op, consoleNeeded)), event: .operationCanceled(op), expectedStatus: "canceled", expectedEffects: []),
            .init(name: "request interrupted: inspect", from: state(.preflight, .startRequested(request: pending, resuming: nil)), event: .startRequestInterrupted(request: pending), expectedStatus: "awaitingInspection", expectedEffects: [.inspectActualState(.preflight, next, operation: nil)]),
            .init(name: "checkpoint reached waits for persistence", from: state(.preflight, .inProgress(op)), event: .checkpointReached(op, checkpoint(.preflight)), expectedStatus: "persistingCheckpoint", expectedEffects: [.persistCheckpoint(checkpoint(.preflight), pending)]),
            .init(name: "persisted checkpoint completes the stage", from: state(.preflight, .persistingCheckpoint(checkpoint(.preflight), operation: op, write: pending)), event: .checkpointPersisted(pending, checkpoint(.preflight)), expectedStatus: "completed", expectedEffects: []),
            .init(name: "persistence failure is shown with its recovery", from: state(.preflight, .persistingCheckpoint(checkpoint(.preflight), operation: op, write: pending)), event: .checkpointPersistenceFailed(pending, failure), expectedStatus: "recoverableFailure", expectedEffects: []),
            .init(name: "request next stage after completion", from: state(.preflight, .completed(checkpoint(.preflight))), event: .startRequested(stage: .runtimeReady), expectedStatus: "startRequested", expectedEffects: []),
            .init(name: "request resumes from durable partial work", from: state(.runtimeReady, .resumable(evidence)), event: .startRequested(stage: .runtimeReady), expectedStatus: "startRequested", expectedEffects: []),
            .init(name: "failure is recoverable", from: state(.sshPaired, .inProgress(op)), event: .operationFailed(op, failure), expectedStatus: "recoverableFailure", expectedEffects: []),
            .init(name: "cancel", from: state(.sshPaired, .inProgress(op)), event: .operationCanceled(op), expectedStatus: "canceled", expectedEffects: []),
            .init(name: "user action required", from: state(.needsGuestSetup, .inProgress(op)), event: .userActionRequired(op, consoleNeeded), expectedStatus: "needsUserAction", expectedEffects: []),
            .init(name: "interruption becomes unknown and inspects", from: state(.macOSInstalled, .inProgress(op)), event: .connectionInterrupted(op), expectedStatus: "unknownOutcome", expectedEffects: [.inspectActualState(.macOSInstalled, pending, operation: op)]),
            .init(name: "still disconnected: inspect again", from: state(.macOSInstalled, .unknownOutcome(op, inspection: pending)), event: .connectionInterrupted(op), expectedStatus: "unknownOutcome", expectedEffects: [.inspectActualState(.macOSInstalled, next, operation: op)]),
            .init(name: "user asks to check again while unknown", from: state(.macOSInstalled, .unknownOutcome(op, inspection: pending)), event: .userRetried, expectedStatus: "unknownOutcome", expectedEffects: [.inspectActualState(.macOSInstalled, next, operation: op)]),
            .init(name: "user asks to check again while inspecting", from: state(.macOSInstalled, .awaitingInspection(pending)), event: .userRetried, expectedStatus: "awaitingInspection", expectedEffects: [.inspectActualState(.macOSInstalled, next, operation: nil)]),
            .init(name: "retry after failure inspects first", from: state(.sshPaired, .recoverableFailure(failure, interrupted: nil)), event: .userRetried, expectedStatus: "awaitingInspection", expectedEffects: [.inspectActualState(.sshPaired, pending, operation: nil)]),
            .init(name: "retry after cancel inspects first", from: state(.sshPaired, .canceled), event: .userRetried, expectedStatus: "awaitingInspection", expectedEffects: [.inspectActualState(.sshPaired, pending, operation: nil)]),
            .init(name: "user finished console step, inspect under the paused operation's identity", from: state(.needsGuestSetup, .needsUserAction(op, consoleNeeded)), event: .userActionCompleted, expectedStatus: "unknownOutcome", expectedEffects: [.inspectActualState(.needsGuestSetup, pending, operation: op)]),
            .init(name: "a paused operation that fails is a recoverable failure", from: state(.needsGuestSetup, .needsUserAction(op, consoleNeeded)), event: .operationFailed(op, failure), expectedStatus: "recoverableFailure", expectedEffects: []),
            .init(name: "a paused operation's checkpoint is persisted", from: state(.needsGuestSetup, .needsUserAction(op, consoleNeeded)), event: .checkpointReached(op, checkpoint(.needsGuestSetup)), expectedStatus: "persistingCheckpoint", expectedEffects: [.persistCheckpoint(checkpoint(.needsGuestSetup), pending)]),
            .init(name: "a failed inspection is a recoverable failure, not a silent loop", from: state(.sshPaired, .awaitingInspection(pending)), event: .inspectionFailed(pending, failure), expectedStatus: "recoverableFailure", expectedEffects: []),
            .init(name: "reconciled: actually completed, persist it", from: state(.macOSInstalled, .unknownOutcome(op, inspection: pending)), event: .operationReconciled(pending, op, .quiescent(.completed(checkpoint(.macOSInstalled)))), expectedStatus: "persistingCheckpoint", expectedEffects: [.persistCheckpoint(checkpoint(.macOSInstalled), next)]),
            .init(name: "reconciled: still running, resume monitoring", from: state(.macOSInstalled, .unknownOutcome(op, inspection: pending)), event: .operationReconciled(pending, op, .stillRunning), expectedStatus: "inProgress", expectedEffects: []),
            .init(name: "reconciled: still waiting on the user", from: state(.needsGuestSetup, .unknownOutcome(op, inspection: pending)), event: .operationReconciled(pending, op, .stillNeedsUserAction(consoleNeeded)), expectedStatus: "needsUserAction", expectedEffects: []),
            .init(name: "reconciled: resumable partial work", from: state(.runtimeReady, .unknownOutcome(op, inspection: pending)), event: .operationReconciled(pending, op, .quiescent(.resumable(evidence))), expectedStatus: "resumable", expectedEffects: []),
            .init(name: "reconciled: failed and needs cleanup", from: state(.runtimeReady, .awaitingInspection(pending)), event: .reconciled(pending, .failedNeedsCleanup(failure)), expectedStatus: "cleanupRequired", expectedEffects: [.cleanUp(.runtimeReady, next)]),
            .init(name: "reconciled: the earlier cleanup is still running", from: state(.runtimeReady, .awaitingInspection(next)), event: .reconciled(next, .cleanupRunning(pending, failure)), expectedStatus: "cleanupRequired", expectedEffects: []),
            .init(name: "reconciled: failed, user must act", from: state(.sshPaired, .awaitingInspection(pending)), event: .reconciled(pending, .failed(failure)), expectedStatus: "recoverableFailure", expectedEffects: []),
            .init(name: "reconciled: nothing happened, safe to start", from: state(.sshPaired, .awaitingInspection(pending)), event: .reconciled(pending, .notStarted), expectedStatus: "notStarted", expectedEffects: []),
            .init(name: "cleanup finished, safe to start", from: state(.runtimeReady, .cleanupRequired(failure, cleanup: pending)), event: .cleanupFinished(pending), expectedStatus: "notStarted", expectedEffects: []),
            .init(name: "cleanup failed, back to recoverable", from: state(.runtimeReady, .cleanupRequired(failure, cleanup: pending)), event: .cleanupFailed(pending, failure), expectedStatus: "recoverableFailure", expectedEffects: []),
        ]
    }

    @Test func everyLegalTransition() throws {
        for transition in legalTransitions {
            let (state, effects) = try Reducer.reduce(transition.from, transition.event)
            #expect(state.status.caseName == transition.expectedStatus, Comment(rawValue: transition.name))
            #expect(effects == transition.expectedEffects, Comment(rawValue: transition.name))
            if case .startRequested(let stage) = transition.event {
                #expect(state.stage == stage, Comment(rawValue: transition.name))
            } else {
                #expect(state.stage == transition.from.stage, Comment(rawValue: transition.name))
            }
            #expect(state.isConsistent, Comment(rawValue: transition.name))
        }
    }

    @Test func nothingAdvancesUntilTheCheckpointIsPersisted() {
        let writing = state(.preflight, .persistingCheckpoint(checkpoint(.preflight), operation: op, write: pending))
        #expect(throws: ProvisioningTransitionError.illegalTransition(status: "persistingCheckpoint", event: "startRequested")) {
            try Reducer.reduce(writing, .startRequested(stage: .runtimeReady))
        }
        #expect(throws: ProvisioningTransitionError.checkpointMismatch(expected: checkpoint(.preflight), actual: checkpoint(.runtimeReady))) {
            try Reducer.reduce(writing, .checkpointPersisted(pending, checkpoint(.runtimeReady)))
        }
    }

    @Test func startingFromAFailureUnknownOrInspectionIsIllegal() {
        for status in [StageStatus.recoverableFailure(failure, interrupted: nil), .unknownOutcome(op, inspection: pending), .awaitingInspection(pending), .cleanupRequired(failure, cleanup: pending), .needsUserAction(op, consoleNeeded), .startRequested(request: pending, resuming: nil), .inProgress(op)] {
            #expect(throws: ProvisioningTransitionError.self, Comment(rawValue: status.caseName)) {
                try Reducer.reduce(state(.sshPaired, status), .startRequested(stage: .sshPaired))
            }
        }
        for status in [StageStatus.notStarted, .resumable(evidence), .completed(checkpoint(.sshPaired))] {
            #expect(throws: ProvisioningTransitionError.self, Comment(rawValue: status.caseName)) {
                try Reducer.reduce(state(.sshPaired, status), .operationStarted(other, stage: .sshPaired, request: pending))
            }
        }
    }

    @Test func reentrantStartIsRejectedWhileTheFirstRequestIsInFlight() throws {
        let reserved = try Reducer.reduce(.initial, .startRequested(stage: .preflight)).state
        #expect(throws: ProvisioningTransitionError.illegalTransition(status: "startRequested", event: "startRequested")) {
            try Reducer.reduce(reserved, .startRequested(stage: .preflight))
        }
        let request = try #require(reserved.status.pendingEffect)
        let running = try Reducer.reduce(reserved, .operationStarted(op, stage: .preflight, request: request)).state
        #expect(throws: ProvisioningTransitionError.self) { try Reducer.reduce(running, .operationStarted(other, stage: .preflight, request: request)) }
    }

    @Test func confirmedFailureWithLeftoversReachesASafeStart() throws {
        let verification = GuesthouseError.downloadVerificationFailed(artifact: "restore image", check: .digest)
        var state = state(.runtimeReady, .recoverableFailure(verification, interrupted: nil))
        let inspecting = try Reducer.reduce(state, .userRetried)
        state = inspecting.state
        let (afterInspection, effects) = try Reducer.reduce(state, .reconciled(try token(of: inspecting.effects), .failedNeedsCleanup(verification)))
        #expect(effects == [.cleanUp(.runtimeReady, EffectToken(2))])
        let clean = try Reducer.reduce(afterInspection, .cleanupFinished(try token(of: effects))).state
        #expect(clean.status == .notStarted)
        let reserved = try Reducer.reduce(clean, .startRequested(stage: .runtimeReady)).state
        let started = try Reducer.reduce(reserved, .operationStarted(other, stage: .runtimeReady, request: #require(reserved.status.pendingEffect))).state
        #expect(started.status == .inProgress(other))
    }

    @Test func eventsForAnotherOperationAreRejected() {
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: op, actual: other)) {
            try Reducer.reduce(state(.preflight, .inProgress(op)), .checkpointReached(other, checkpoint(.preflight)))
        }
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: op, actual: other)) {
            try Reducer.reduce(state(.preflight, .unknownOutcome(op, inspection: pending)), .connectionInterrupted(other))
        }
    }

    @Test func stagesMustBeSequential() {
        #expect(throws: ProvisioningTransitionError.stageMismatch(expected: .runtimeReady, actual: .sshPaired)) {
            try Reducer.reduce(state(.preflight, .completed(checkpoint(.preflight))), .startRequested(stage: .sshPaired))
        }
        #expect(throws: ProvisioningTransitionError.stageMismatch(expected: .preflight, actual: .ready)) {
            try Reducer.reduce(state(.preflight, .inProgress(op)), .checkpointReached(op, checkpoint(.ready)))
        }
        #expect(throws: ProvisioningTransitionError.alreadyReady) {
            try Reducer.reduce(state(.ready, .completed(checkpoint(.ready))), .startRequested(stage: .ready))
        }
    }

    @Test func retryingWhileInProgressOrCompletedIsIllegal() {
        #expect(throws: ProvisioningTransitionError.self) { try Reducer.reduce(state(.preflight, .inProgress(op)), .userRetried) }
        #expect(throws: ProvisioningTransitionError.self) { try Reducer.reduce(state(.preflight, .completed(checkpoint(.preflight))), .userRetried) }
        #expect(throws: ProvisioningTransitionError.self) { try Reducer.reduce(.initial, .reconciled(pending, .notStarted)) }
        #expect(throws: ProvisioningTransitionError.self) { try Reducer.reduce(.initial, .cleanupFinished(pending)) }
    }

    @Test func happyPathReachesReadyOnlyAfterEveryCheckpointIsPersisted() throws {
        var state = ProvisioningState.initial
        for stage in ProvisioningStage.allCases {
            let id = OperationID()
            state = try Reducer.reduce(state, .startRequested(stage: stage)).state
            state = try Reducer.reduce(state, .operationStarted(id, stage: stage, request: #require(state.status.pendingEffect))).state
            let reached = try Reducer.reduce(state, .checkpointReached(id, checkpoint(stage)))
            state = reached.state
            #expect(!state.isReady)
            state = try Reducer.reduce(state, .checkpointPersisted(try token(of: reached.effects), checkpoint(stage))).state
        }
        #expect(state.isReady)
        #expect(state.stage == .ready)
    }

    @Test func readinessRequiresTheFinalCheckpointItself() {
        #expect(!state(.ready, .persistingCheckpoint(checkpoint(.ready), operation: op, write: pending)).isReady)
        #expect(state(.ready, .completed(checkpoint(.ready))).isReady)
        #expect(!ProvisioningState.isConsistent(stage: .ready, status: .completed(checkpoint(.preflight))))
        #expect(ProvisioningState.isConsistent(stage: .ready, status: .notStarted))
    }

    @Test func interruptedThenCompletedContinuesToNextStage() throws {
        var state = state(.macOSInstalled, .inProgress(op))
        let inspecting = try Reducer.reduce(state, .connectionInterrupted(op))
        let reconciled = try Reducer.reduce(inspecting.state, .operationReconciled(try token(of: inspecting.effects), op, .quiescent(.completed(checkpoint(.macOSInstalled)))))
        state = try Reducer.reduce(reconciled.state, .checkpointPersisted(try token(of: reconciled.effects), checkpoint(.macOSInstalled))).state
        state = try Reducer.reduce(state, .startRequested(stage: .needsGuestSetup)).state
        state = try Reducer.reduce(state, .operationStarted(other, stage: .needsGuestSetup, request: #require(state.status.pendingEffect))).state
        #expect(state.stage == .needsGuestSetup)
        #expect(state.status == .inProgress(other))
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

    @Test func transitionErrorsCarryUserFacingText() {
        for error in [ProvisioningTransitionError.illegalTransition(status: "a", event: "b"), .operationMismatch(expected: op, actual: other), .stageMismatch(expected: .preflight, actual: .ready), .checkpointMismatch(expected: checkpoint(.preflight), actual: checkpoint(.ready)), .staleEffect(expected: pending, actual: next), .staleStartRequest(expected: pending, actual: next), .inspectionWhileStartRequestLive, .alreadyReady] {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
            #expect(!error.recoveryActions.isEmpty)
        }
        #expect(ProvisioningTransitionError.illegalTransition(status: "a", event: "b").recoveryActions.first == .inspectState)
        #expect(ProvisioningTransitionError.staleEffect(expected: pending, actual: next).recoveryActions.first == .inspectState)
        #expect(!ProvisioningTransitionError.staleStartRequest(expected: pending, actual: next).recoveryActions.contains(.inspectState))
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
}
