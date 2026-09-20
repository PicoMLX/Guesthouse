import Foundation
import Testing
import GuesthouseCore

@Suite struct ProvisioningInspectionOrderingTests {
    let operation = OperationID()
    let inspection = EffectToken(7)
    let checkpoint = Checkpoint(stage: .first, reachedAt: Date(timeIntervalSince1970: 1_800_000_000))

    func inspected() -> ProvisioningState {
        ProvisioningState(stage: .first, status: .unknownOutcome(operation, inspection: inspection))
    }

    func rejectOldInspection(_ state: ProvisioningState) {
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(state, .operationReconciled(inspection, operation, .stillRunning(stage: .first)))
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(state, .inspectionFailed(inspection, .runtimeMissing))
        }
    }

    @Test func reachedCheckpointSupersedesPendingInspection() throws {
        let result = try ProvisioningReducer.reduce(inspected(), .checkpointReached(operation, checkpoint))
        let write = EffectToken(8)
        #expect(result.state.status == .persistingCheckpoint(checkpoint, operation: operation, write: write))
        #expect(result.effects == [.persistCheckpoint(checkpoint, write)])
        rejectOldInspection(result.state)
        let saved = try ProvisioningReducer.reduce(result.state, .checkpointPersisted(write, checkpoint))
        #expect(saved.state.status == .completed(checkpoint))
    }

    @Test func reportedFailureSupersedesInspectionButRetainsUnknownMutation() throws {
        let result = try ProvisioningReducer.reduce(inspected(), .operationFailed(operation, .canceled))
        #expect(result.state.status == .recoverableFailure(.canceled, interrupted: operation))
        #expect(result.effects.isEmpty)
        rejectOldInspection(result.state)
        let retry = try ProvisioningReducer.reduce(result.state, .userRetried)
        #expect(retry.effects == [.inspectActualState(.first, EffectToken(8), operation: operation)])
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: EffectToken(8), actual: inspection)) {
            try ProvisioningReducer.reduce(retry.state, .operationReconciled(inspection, operation, .stillRunning(stage: .first)))
        }
    }

    @Test func confirmedCancellationSupersedesPendingInspection() throws {
        let result = try ProvisioningReducer.reduce(inspected(), .operationCanceled(operation))
        #expect(result.state.status == .canceled)
        #expect(result.effects.isEmpty)
        rejectOldInspection(result.state)
    }

    @Test func userActionPromptSupersedesPendingInspection() throws {
        let result = try ProvisioningReducer.reduce(inspected(), .userActionRequired(operation, .runtimeMissing))
        #expect(result.state.status == .needsUserAction(operation, .runtimeMissing))
        #expect(result.effects.isEmpty)
        rejectOldInspection(result.state)
    }

    @Test(arguments: [ProvisioningEvent.Kind.checkpointReached, .operationFailed, .operationCanceled, .userActionRequired])
    func foreignCallbackCannotInvalidateInspection(kind: ProvisioningEvent.Kind) throws {
        let other = OperationID()
        let event: ProvisioningEvent
        switch kind {
        case .checkpointReached: event = .checkpointReached(other, checkpoint)
        case .operationFailed: event = .operationFailed(other, .canceled)
        case .operationCanceled: event = .operationCanceled(other)
        case .userActionRequired: event = .userActionRequired(other, .runtimeMissing)
        default: Issue.record("unexpected callback kind"); return
        }
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: other)) {
            try ProvisioningReducer.reduce(inspected(), event)
        }
        let accepted = try ProvisioningReducer.reduce(inspected(), .operationReconciled(inspection, operation, .stillRunning(stage: .first)))
        #expect(accepted.state.status == .inProgress(operation))
    }

    @Test func checkpointAtAnotherStageCannotInvalidateInspection() throws {
        let later = Checkpoint(stage: .ready, reachedAt: checkpoint.reachedAt)
        #expect(throws: ProvisioningTransitionError.stageMismatch(expected: .first, actual: .ready)) {
            try ProvisioningReducer.reduce(inspected(), .checkpointReached(operation, later))
        }
    }
}
