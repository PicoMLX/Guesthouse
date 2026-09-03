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

    func checkpoint(_ stage: ProvisioningStage) -> Checkpoint { Checkpoint(stage: stage, reachedAt: now) }
    func state(_ stage: ProvisioningStage, _ status: StageStatus) -> ProvisioningState { ProvisioningState(stage: stage, status: status) }

    struct LegalTransition: CustomTestStringConvertible {
        let name: String
        let from: ProvisioningState
        let event: ProvisioningEvent
        let expectedStatus: String
        let expectedEffects: [ProvisioningEffect]
        var testDescription: String { name }
    }

    var legalTransitions: [LegalTransition] {
        [
            .init(name: "start first stage", from: .initial, event: .operationStarted(op, stage: .preflight), expectedStatus: "inProgress", expectedEffects: []),
            .init(name: "checkpoint completes stage and persists", from: state(.preflight, .inProgress(op)), event: .checkpointReached(op, checkpoint(.preflight)), expectedStatus: "completed", expectedEffects: [.persistCheckpoint(checkpoint(.preflight))]),
            .init(name: "start next stage after completion", from: state(.preflight, .completed(checkpoint(.preflight))), event: .operationStarted(op, stage: .runtimeReady), expectedStatus: "inProgress", expectedEffects: []),
            .init(name: "failure is recoverable", from: state(.sshPaired, .inProgress(op)), event: .operationFailed(op, failure), expectedStatus: "recoverableFailure", expectedEffects: []),
            .init(name: "cancel", from: state(.sshPaired, .inProgress(op)), event: .operationCanceled(op), expectedStatus: "canceled", expectedEffects: []),
            .init(name: "user action required", from: state(.needsGuestSetup, .inProgress(op)), event: .userActionRequired(op, consoleNeeded), expectedStatus: "needsUserAction", expectedEffects: []),
            .init(name: "interruption becomes unknown and inspects", from: state(.macOSInstalled, .inProgress(op)), event: .connectionInterrupted(op), expectedStatus: "unknownOutcome", expectedEffects: [.inspectActualState(.macOSInstalled)]),
            .init(name: "retry after failure inspects first", from: state(.sshPaired, .recoverableFailure(failure)), event: .userRetried, expectedStatus: "awaitingInspection", expectedEffects: [.inspectActualState(.sshPaired)]),
            .init(name: "retry after cancel inspects first", from: state(.sshPaired, .canceled), event: .userRetried, expectedStatus: "awaitingInspection", expectedEffects: [.inspectActualState(.sshPaired)]),
            .init(name: "user finished console step, inspect", from: state(.needsGuestSetup, .needsUserAction(consoleNeeded)), event: .userActionCompleted, expectedStatus: "awaitingInspection", expectedEffects: [.inspectActualState(.needsGuestSetup)]),
            .init(name: "reconciled: actually completed", from: state(.macOSInstalled, .unknownOutcome(op)), event: .reconciled(.completed(checkpoint(.macOSInstalled))), expectedStatus: "completed", expectedEffects: [.persistCheckpoint(checkpoint(.macOSInstalled))]),
            .init(name: "reconciled: actually failed", from: state(.macOSInstalled, .unknownOutcome(op)), event: .reconciled(.failed(failure)), expectedStatus: "recoverableFailure", expectedEffects: []),
            .init(name: "reconciled: nothing happened, safe to start", from: state(.sshPaired, .awaitingInspection), event: .reconciled(.notStarted), expectedStatus: "notStarted", expectedEffects: []),
            .init(name: "reconciled after inspection: completed", from: state(.sshPaired, .awaitingInspection), event: .reconciled(.completed(checkpoint(.sshPaired))), expectedStatus: "completed", expectedEffects: [.persistCheckpoint(checkpoint(.sshPaired))]),
        ]
    }

    @Test func everyLegalTransition() throws {
        for transition in legalTransitions {
            let (state, effects) = try Reducer.reduce(transition.from, transition.event)
            #expect(state.status.caseName == transition.expectedStatus, "\(transition.name)")
            #expect(effects == transition.expectedEffects, "\(transition.name)")
            if case .operationStarted(_, let stage) = transition.event {
                #expect(state.stage == stage, "\(transition.name): operationStarted moves to the requested stage")
            } else {
                #expect(state.stage == transition.from.stage, "\(transition.name): only operationStarted changes the stage")
            }
        }
    }

    @Test func startingFromAFailureWithoutInspectionIsIllegal() {
        let from = state(.sshPaired, .recoverableFailure(failure))
        #expect(throws: ProvisioningTransitionError.illegalTransition(status: "recoverableFailure", event: "operationStarted")) {
            try Reducer.reduce(from, .operationStarted(op, stage: .sshPaired))
        }
    }

    @Test func startingWhileUnknownOrInspectingIsIllegal() {
        #expect(throws: ProvisioningTransitionError.self) {
            try Reducer.reduce(state(.sshPaired, .unknownOutcome(op)), .operationStarted(other, stage: .sshPaired))
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try Reducer.reduce(state(.sshPaired, .awaitingInspection), .operationStarted(other, stage: .sshPaired))
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try Reducer.reduce(state(.sshPaired, .inProgress(op)), .operationStarted(other, stage: .guestSecured))
        }
    }

    @Test func eventsForAnotherOperationAreRejected() {
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: op, actual: other)) {
            try Reducer.reduce(state(.preflight, .inProgress(op)), .checkpointReached(other, checkpoint(.preflight)))
        }
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: op, actual: other)) {
            try Reducer.reduce(state(.preflight, .inProgress(op)), .connectionInterrupted(other))
        }
    }

    @Test func stagesMustBeSequential() {
        #expect(throws: ProvisioningTransitionError.stageMismatch(expected: .runtimeReady, actual: .sshPaired)) {
            try Reducer.reduce(state(.preflight, .completed(checkpoint(.preflight))), .operationStarted(op, stage: .sshPaired))
        }
        #expect(throws: ProvisioningTransitionError.stageMismatch(expected: .preflight, actual: .ready)) {
            try Reducer.reduce(state(.preflight, .inProgress(op)), .checkpointReached(op, checkpoint(.ready)))
        }
        #expect(throws: ProvisioningTransitionError.alreadyReady) {
            try Reducer.reduce(state(.ready, .completed(checkpoint(.ready))), .operationStarted(op, stage: .ready))
        }
    }

    @Test func retryingWhileInProgressOrCompletedIsIllegal() {
        #expect(throws: ProvisioningTransitionError.self) {
            try Reducer.reduce(state(.preflight, .inProgress(op)), .userRetried)
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try Reducer.reduce(state(.preflight, .completed(checkpoint(.preflight))), .userRetried)
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try Reducer.reduce(.initial, .reconciled(.notStarted))
        }
    }

    @Test func happyPathReachesReady() throws {
        var state = ProvisioningState.initial
        for stage in ProvisioningStage.allCases {
            let id = OperationID()
            state = try Reducer.reduce(state, .operationStarted(id, stage: stage)).state
            state = try Reducer.reduce(state, .checkpointReached(id, checkpoint(stage))).state
        }
        #expect(state.isReady)
        #expect(state.stage == .ready)
    }

    @Test func interruptedThenCompletedContinuesToNextStage() throws {
        var state = state(.macOSInstalled, .inProgress(op))
        state = try Reducer.reduce(state, .connectionInterrupted(op)).state
        #expect(state.status == .unknownOutcome(op))
        state = try Reducer.reduce(state, .reconciled(.completed(checkpoint(.macOSInstalled)))).state
        state = try Reducer.reduce(state, .operationStarted(other, stage: .needsGuestSetup)).state
        #expect(state == self.state(.needsGuestSetup, .inProgress(other)))
    }

    @Test func stateRoundTripsThroughJSON() throws {
        let states = [
            ProvisioningState.initial,
            state(.sshPaired, .recoverableFailure(failure)),
            state(.macOSInstalled, .unknownOutcome(op)),
            state(.ready, .completed(checkpoint(.ready))),
        ]
        for original in states {
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(ProvisioningState.self, from: data) == original)
        }
    }
}
