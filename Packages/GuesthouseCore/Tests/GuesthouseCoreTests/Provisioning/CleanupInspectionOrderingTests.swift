import Foundation
import Testing
import GuesthouseCore

@Suite struct CleanupInspectionOrderingTests {
    let cleanup = EffectToken(4)
    let inspection = EffectToken(5)

    func checking() -> ProvisioningState {
        ProvisioningState(stage: .first, status: .inspectingCleanup(.canceled, cleanup: cleanup, inspection: inspection))
    }

    @Test(arguments: [ProvisioningEvent.inspectionRequested, .userRetried])
    func completionInvalidatesOldRunningReply(request: ProvisioningEvent) throws {
        let initial = ProvisioningState(stage: .first, status: .cleanupRequired(.canceled, cleanup: cleanup))
        let inspecting = try ProvisioningReducer.reduce(initial, request)
        #expect(inspecting.state == checking())
        #expect(inspecting.effects == [.inspectActualState(.first, inspection, operation: nil)])
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(inspecting.state))
        let finished = try ProvisioningReducer.reduce(restored, .cleanupFinished(cleanup))
        #expect(finished.state.status == .notStarted)
        #expect(finished.effects.isEmpty)
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(finished.state, .reconciled(inspection, .cleanupRunning(cleanup, .canceled)))
        }
    }

    @Test func cleanupFailureInvalidatesOldRunningReply() throws {
        let failed = try ProvisioningReducer.reduce(checking(), .cleanupFailed(cleanup, .runtimeMissing))
        #expect(failed.state.status == .recoverableFailure(.runtimeMissing, interrupted: nil))
        #expect(failed.effects.isEmpty)
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(failed.state, .reconciled(inspection, .cleanupRunning(cleanup, .canceled)))
        }
        let retry = try ProvisioningReducer.reduce(failed.state, .userRetried)
        #expect(retry.effects == [.inspectActualState(.first, EffectToken(6), operation: nil)])
    }

    @Test func failedInspectionRetainsLiveCleanup() throws {
        let failed = try ProvisioningReducer.reduce(checking(), .inspectionFailed(inspection, .runtimeMissing))
        #expect(failed.state.status == .cleanupRequired(.runtimeMissing, cleanup: cleanup))
        #expect(failed.effects.isEmpty)
        let finished = try ProvisioningReducer.reduce(failed.state, .cleanupFinished(cleanup))
        #expect(finished.state.status == .notStarted)
    }

    @Test(arguments: [ProvisioningEvent.inspectionRequested, .userRetried])
    func reinspectionKeepsCleanupButRejectsOldInspection(request: ProvisioningEvent) throws {
        let newer = try ProvisioningReducer.reduce(checking(), request)
        #expect(newer.state.status == .inspectingCleanup(.canceled, cleanup: cleanup, inspection: EffectToken(6)))
        #expect(newer.effects == [.inspectActualState(.first, EffectToken(6), operation: nil)])
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: EffectToken(6), actual: inspection)) {
            try ProvisioningReducer.reduce(newer.state, .reconciled(inspection, .notStarted))
        }
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: cleanup, actual: EffectToken(3))) {
            try ProvisioningReducer.reduce(newer.state, .cleanupFinished(EffectToken(3)))
        }
        #expect(try ProvisioningReducer.reduce(newer.state, .cleanupFinished(cleanup)).state.status == .notStarted)
    }

    @Test(arguments: [
        ReconciledOutcome.stillRunning(OperationID()),
        .stillNeedsUserAction(OperationID(), .runtimeMissing),
        .cleanupRunning(EffectToken(3), .canceled),
    ])
    func inspectionCannotReplaceCleanupWithAnotherMutation(outcome: ReconciledOutcome) throws {
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(checking(), .reconciled(inspection, outcome))
        }
        let resumed = try ProvisioningReducer.reduce(checking(), .reconciled(inspection, .cleanupRunning(cleanup, .canceled)))
        #expect(resumed.state.status == .cleanupRequired(.canceled, cleanup: cleanup))
        #expect(resumed.effects.isEmpty)
    }

    @Test(arguments: [(UInt64.max, UInt64(7)), (UInt64(7), UInt64.max)])
    func eitherOutstandingTokenPreservesExhaustion(cleanup: UInt64, inspection: UInt64) throws {
        let state = ProvisioningState(stage: .first, status: .inspectingCleanup(.canceled, cleanup: EffectToken(cleanup), inspection: EffectToken(inspection)))
        let restored = try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(state))
        #expect(restored.issuedEffects == UInt64.max)
        #expect(restored.nextEffectToken == nil)
        #expect(throws: ProvisioningTransitionError.effectCounterExhausted) {
            try ProvisioningReducer.reduce(restored, .inspectionRequested)
        }
        #expect(try ProvisioningReducer.reduce(restored, .cleanupFinished(EffectToken(cleanup))).state.status == .notStarted)
    }
}
