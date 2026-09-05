import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningTransitionErrorTests {
    let op = OperationID()
    let other = OperationID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let pending = EffectToken(1)
    let next = EffectToken(2)

    func checkpoint(_ stage: ProvisioningStage) -> Checkpoint { Checkpoint(stage: stage, reachedAt: now) }

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
}
