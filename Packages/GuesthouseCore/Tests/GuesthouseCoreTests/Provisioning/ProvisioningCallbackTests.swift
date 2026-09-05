import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningCallbackTests {
    typealias Reducer = ProvisioningReducer

    let op = OperationID()
    let other = OperationID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let pending = EffectToken(1)

    func checkpoint(_ stage: ProvisioningStage) -> Checkpoint { Checkpoint(stage: stage, reachedAt: now) }
    func state(_ stage: ProvisioningStage, _ status: StageStatus) -> ProvisioningState { ProvisioningState(stage: stage, status: status) }

    @Test func reentrantStartIsRejectedWhileTheFirstRequestIsInFlight() throws {
        let reserved = try Reducer.reduce(.initial, .startRequested(stage: .preflight)).state
        #expect(throws: ProvisioningTransitionError.illegalTransition(status: "startRequested", event: "startRequested")) {
            try Reducer.reduce(reserved, .startRequested(stage: .preflight))
        }
        let request = try #require(reserved.status.pendingEffect)
        let running = try Reducer.reduce(reserved, .operationStarted(op, stage: .preflight, request: request)).state
        #expect(throws: ProvisioningTransitionError.self) { try Reducer.reduce(running, .operationStarted(other, stage: .preflight, request: request)) }
    }

    @Test func eventsForAnotherOperationAreRejected() {
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: op, actual: other)) {
            try Reducer.reduce(state(.preflight, .inProgress(op)), .checkpointReached(other, checkpoint(.preflight)))
        }
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: op, actual: other)) {
            try Reducer.reduce(state(.preflight, .unknownOutcome(op, inspection: pending)), .connectionInterrupted(other))
        }
    }
}
