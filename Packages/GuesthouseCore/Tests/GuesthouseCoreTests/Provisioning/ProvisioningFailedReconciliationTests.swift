import Foundation
import GuesthouseCore
import Testing

@Suite struct ProvisioningFailedReconciliationTests {
    @Test(arguments: ProvisioningStage.allCases)
    func interruptedOperationConfirmedFailedStillInspectsBeforeRetry(stage: ProvisioningStage) throws {
        let operation = OperationID()
        let active = ProvisioningState(stage: stage, status: .inProgress(operation))
        let interrupted = try ProvisioningReducer.reduce(active, .connectionInterrupted(operation))
        let inspection = try #require(interrupted.state.status.pendingEffect)
        #expect(interrupted.state.status == .unknownOutcome(operation, inspection: inspection))
        #expect(interrupted.effects == [.inspectActualState(stage, inspection, operation: operation)])
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(interrupted.state))

        let failed = try ProvisioningReducer.reduce(restored,
            .operationReconciled(inspection, operation, .quiescent(.failed(.runtimeMissing))))
        #expect(failed.state.status == .recoverableFailure(.runtimeMissing, interrupted: nil))
        #expect(failed.state.stage == stage)
        #expect(failed.effects.isEmpty)
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(failed.state, .startRequested(stage: stage))
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(failed.state,
                .operationReconciled(inspection, operation, .stillRunning(stage: stage)))
        }

        let relaunched = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(failed.state))
        let retry = try ProvisioningReducer.reduce(relaunched, .userRetried)
        #expect(retry.state.status == .awaitingInspection(EffectToken(2)))
        #expect(retry.effects == [.inspectActualState(stage, EffectToken(2), operation: nil)])
    }
}
