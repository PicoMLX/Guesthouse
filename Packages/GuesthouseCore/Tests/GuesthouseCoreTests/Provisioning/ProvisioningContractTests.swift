import Foundation
import Testing
@testable import GuesthouseCore

private let operation = OperationID()
private let otherOperation = OperationID()
private let token = EffectToken(1)
private let nextToken = EffectToken(2)
private let checkpoint = Checkpoint(stage: .first, reachedAt: Date(timeIntervalSince1970: 0))
private let laterCheckpoint = Checkpoint(stage: .ready, reachedAt: Date(timeIntervalSince1970: 1))

@Suite struct ProvisioningTransitionErrorTests {
    @Test(arguments: [
        (ProvisioningTransitionError.illegalTransition(status: .inProgress, event: .operationStarted), [RecoveryAction.inspectState, .cancel]),
        (.operationMismatch(expected: operation, actual: otherOperation), [.inspectState, .cancel]),
        (.stageMismatch(expected: .first, actual: .ready), [.inspectState, .cancel]),
        (.checkpointMismatch(expected: checkpoint, actual: laterCheckpoint), [.inspectState, .cancel]),
        (.staleEffect(expected: token, actual: nextToken), [.inspectState, .cancel]),
        (.staleStartRequest(expected: token, actual: nextToken), [.cancel]),
        (.inspectionWhileStartRequestLive, [.cancel]), (.alreadyReady, [.inspectState, .cancel]),
    ])
    func transitionErrorsCarryUsefulFixedTextAndLegalRecovery(error: ProvisioningTransitionError, actions: [RecoveryAction]) {
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.recoverySuggestion?.isEmpty == false)
        #expect(error.recoveryActions == actions)
        #expect(!error.recoveryActions.contains(.retry))
    }

    @Test func associatedIdentityDoesNotEnterDisplayText() {
        let first = ProvisioningTransitionError.operationMismatch(expected: operation, actual: otherOperation)
        let second = ProvisioningTransitionError.operationMismatch(expected: OperationID(), actual: OperationID())
        #expect(first != second)
        #expect(first.userMessage == second.userMessage)
        #expect(first.recoveryMessage == second.recoveryMessage)
        #expect(!first.userMessage.contains(operation.description))
    }

    @Test func finalCheckpointDoesNotPromiseLiveReadiness() {
        #expect(ProvisioningTransitionError.alreadyReady.userMessage == "Guesthouse has recorded the final setup checkpoint. There is no later setup step.")
        #expect(ProvisioningTransitionError.alreadyReady.recoveryMessage == "Check the environment before relying on its saved readiness.")
    }
}

@Suite struct ProvisioningContractTests {
    @Test(arguments: [
        (StageStatus.notStarted, StageStatus.Kind.notStarted),
        (.startRequested(request: token, resuming: nil), .startRequested),
        (.startRejected(.runtimeMissing, resuming: nil), .startRejected),
        (.inProgress(operation), .inProgress),
        (.persistingCheckpoint(checkpoint, operation: operation, write: token), .persistingCheckpoint),
        (.completed(checkpoint), .completed), (.canceled, .canceled),
        (.recoverableFailure(.runtimeMissing, interrupted: operation), .recoverableFailure),
        (.needsUserAction(operation, .runtimeMissing), .needsUserAction),
        (.unknownOutcome(operation, inspection: token), .unknownOutcome),
        (.awaitingInspection(token), .awaitingInspection),
        (.resumable(ResumeEvidence(kind: .partialDownload)!), .resumable),
        (.cleanupRequired(.runtimeMissing, cleanup: token), .cleanupRequired),
    ])
    func statusesMapToClosedKinds(status: StageStatus, expected: StageStatus.Kind) {
        #expect(status.kind == expected)
        #expect(status.caseName == expected.rawValue)
    }

    @Test(arguments: [
        (ProvisioningEvent.startRequested(stage: .first), ProvisioningEvent.Kind.startRequested),
        (.startRequestRejected(.runtimeMissing, request: token), .startRequestRejected),
        (.startRequestInterrupted(request: token), .startRequestInterrupted),
        (.operationStarted(operation, stage: .first, request: token), .operationStarted),
        (.checkpointReached(operation, checkpoint), .checkpointReached),
        (.checkpointPersisted(token, checkpoint), .checkpointPersisted),
        (.checkpointPersistenceFailed(token, .runtimeMissing), .checkpointPersistenceFailed),
        (.operationFailed(operation, .operationOutcomeUnknown(operation)), .operationFailed),
        (.operationCanceled(operation), .operationCanceled),
        (.userActionRequired(operation, .runtimeMissing), .userActionRequired),
        (.connectionInterrupted(operation), .connectionInterrupted),
        (.reconciled(token, .notStarted), .reconciled),
        (.operationReconciled(token, operation, .stillRunning(stage: .first)), .operationReconciled),
        (.inspectionFailed(token, .runtimeMissing), .inspectionFailed),
        (.cleanupFinished(token), .cleanupFinished), (.cleanupFailed(token, .runtimeMissing), .cleanupFailed),
        (.userRetried, .userRetried), (.userActionCompleted, .userActionCompleted),
        (.inspectionRequested, .inspectionRequested),
    ])
    func eventsMapToClosedKinds(event: ProvisioningEvent, expected: ProvisioningEvent.Kind) {
        #expect(event.kind == expected)
        #expect(event.caseName == expected.rawValue)
    }

    @Test func correlationIdentityIsNotFlattenedIntoTheKind() {
        let first = ProvisioningEvent.operationStarted(operation, stage: .first, request: token)
        #expect(first != .operationStarted(otherOperation, stage: .first, request: token))
        #expect(first != .operationStarted(operation, stage: .ready, request: token))
        #expect(first != .operationStarted(operation, stage: .first, request: nextToken))
        #expect(ProvisioningEffect.inspectActualState(.first, token, operation: operation) != .inspectActualState(.first, token, operation: nil))
        #expect(ProvisioningEffect.persistCheckpoint(checkpoint, token) != .persistCheckpoint(checkpoint, nextToken))
        #expect(ProvisioningEffect.cleanUp(.first, token) != .cleanUp(.first, nextToken))
        #expect(StageStatus.Kind.allCases.count == 13)
        #expect(ProvisioningEvent.Kind.allCases.count == 19)
    }

    @Test func newComputedLabelsDoNotChangePersistedStatusLayout() throws {
        let original = ProvisioningState(stage: .first, status: .startRequested(request: token, resuming: nil))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        let status = try #require(encoded["status"] as? [String: Any])
        #expect(Set(status.keys) == ["startRequested"])
        #expect(try JSONDecoder().decode(ProvisioningState.self, from: JSONEncoder().encode(original)) == original)
        #expect(original.schemaVersion.rawValue == 2)
    }
}
