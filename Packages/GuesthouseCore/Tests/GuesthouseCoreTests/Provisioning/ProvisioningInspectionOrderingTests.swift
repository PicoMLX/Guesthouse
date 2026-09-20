import Foundation
import Testing
import GuesthouseCore

@Suite struct ProvisioningInspectionOrderingTests {
    let operation = OperationID()
    let inspection = EffectToken(7)
    let checkpoint = Checkpoint(stage: .first, reachedAt: Date(timeIntervalSince1970: 1_800_000_000))

    func inspected(afterFailure: Bool = false) throws -> ProvisioningState {
        let pending = ProvisioningState(stage: .first, status: .unknownOutcome(operation, inspection: inspection))
        guard afterFailure else { return pending }
        let failed = try ProvisioningReducer.reduce(pending, .inspectionFailed(inspection, .runtimeMissing))
        #expect(failed.state.status == .recoverableFailure(.runtimeMissing, interrupted: operation))
        return try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(failed.state))
    }

    func rejectOldInspection(_ state: ProvisioningState) {
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(state, .operationReconciled(inspection, operation, .stillRunning(stage: .first)))
        }
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(state, .inspectionFailed(inspection, .runtimeMissing))
        }
    }

    @Test(arguments: [false, true])
    func reachedCheckpointSupersedesInspection(afterFailure: Bool) throws {
        let result = try ProvisioningReducer.reduce(inspected(afterFailure: afterFailure), .checkpointReached(operation, checkpoint))
        let write = EffectToken(8)
        #expect(result.state.status == .persistingCheckpoint(checkpoint, operation: operation, write: write))
        #expect(result.effects == [.persistCheckpoint(checkpoint, write)])
        rejectOldInspection(result.state)
        let saved = try ProvisioningReducer.reduce(result.state, .checkpointPersisted(write, checkpoint))
        #expect(saved.state.status == .completed(checkpoint))
    }

    @Test(arguments: [false, true])
    func reportedFailureSupersedesInspectionButRetainsUnknownMutation(afterFailure: Bool) throws {
        let result = try ProvisioningReducer.reduce(inspected(afterFailure: afterFailure), .operationFailed(operation, .canceled))
        #expect(result.state.status == .recoverableFailure(.canceled, interrupted: operation))
        #expect(result.effects.isEmpty)
        rejectOldInspection(result.state)
        let retry = try ProvisioningReducer.reduce(result.state, .userRetried)
        #expect(retry.effects == [.inspectActualState(.first, EffectToken(8), operation: operation)])
        #expect(throws: ProvisioningTransitionError.staleEffect(expected: EffectToken(8), actual: inspection)) {
            try ProvisioningReducer.reduce(retry.state, .operationReconciled(inspection, operation, .stillRunning(stage: .first)))
        }
    }

    @Test(arguments: [false, true])
    func confirmedCancellationSupersedesInspection(afterFailure: Bool) throws {
        let result = try ProvisioningReducer.reduce(inspected(afterFailure: afterFailure), .operationCanceled(operation))
        #expect(result.state.status == .canceled)
        #expect(result.effects.isEmpty)
        rejectOldInspection(result.state)
    }

    @Test(arguments: [false, true])
    func userActionPromptSupersedesInspection(afterFailure: Bool) throws {
        let result = try ProvisioningReducer.reduce(inspected(afterFailure: afterFailure), .userActionRequired(operation, .runtimeMissing))
        #expect(result.state.status == .needsUserAction(operation, .runtimeMissing))
        #expect(result.effects.isEmpty)
        rejectOldInspection(result.state)
    }

    @Test(arguments: [ProvisioningEvent.Kind.checkpointReached, .operationFailed, .operationCanceled, .userActionRequired], [false, true])
    func foreignCallbackCannotInvalidateInspection(kind: ProvisioningEvent.Kind, afterFailure: Bool) throws {
        let other = OperationID()
        let event: ProvisioningEvent
        switch kind {
        case .checkpointReached: event = .checkpointReached(other, checkpoint)
        case .operationFailed: event = .operationFailed(other, .canceled)
        case .operationCanceled: event = .operationCanceled(other)
        case .userActionRequired: event = .userActionRequired(other, .runtimeMissing)
        default: Issue.record("unexpected callback kind"); return
        }
        let state = try inspected(afterFailure: afterFailure)
        #expect(throws: ProvisioningTransitionError.operationMismatch(expected: operation, actual: other)) {
            try ProvisioningReducer.reduce(state, event)
        }
        let retry = try ProvisioningReducer.reduce(state, .inspectionRequested)
        let accepted = try ProvisioningReducer.reduce(retry.state, .operationReconciled(EffectToken(8), operation, .stillRunning(stage: .first)))
        #expect(accepted.state.status == .inProgress(operation))
    }

    @Test(arguments: [false, true])
    func checkpointAtAnotherStageCannotInvalidateInspection(afterFailure: Bool) throws {
        let later = Checkpoint(stage: .ready, reachedAt: checkpoint.reachedAt)
        let state = try inspected(afterFailure: afterFailure)
        #expect(throws: ProvisioningTransitionError.stageMismatch(expected: .first, actual: .ready)) {
            try ProvisioningReducer.reduce(state, .checkpointReached(operation, later))
        }
    }

    @Test func untrackedFailureCannotAdoptAnUnsolicitedCheckpoint() {
        let state = ProvisioningState(stage: .first, status: .recoverableFailure(.runtimeMissing, interrupted: nil))
        #expect(throws: ProvisioningTransitionError.self) {
            try ProvisioningReducer.reduce(state, .checkpointReached(operation, checkpoint))
        }
    }
}
