import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor struct OperationPresentationTests {
    nonisolated static let errors: [GuesthouseError] = [
        .unsupportedHost(.notAppleSilicon), .unsupportedHost(.unknownArchitecture), .unsupportedHost(.macOSTooOld),
        .unsupportedHost(.insufficientMemory(foundBytes: 1, minimumBytes: 2)), .insufficientDisk(requiredBytes: 2, availableBytes: 1),
        .runtimeMissing, .runtimeIncompatible, .guestNotReachable(EnvironmentID()), .hostKeyChanged(EnvironmentID()),
        .guestShutdownRefused(EnvironmentID()), .xcodeComponentsIncomplete, .vmSlotUnavailable(maximum: 2),
        .operationOutcomeUnknown(OperationID()), .unauthorizedCaller, .protocolMismatch(client: 1, service: 2), .canceled
    ] + GuesthouseError.VerificationCheck.allCases.map { .downloadVerificationFailed(check: $0) }
      + GuesthouseError.CredentialStore.allCases.map { .credentialsLocked($0) }
      + GuesthouseError.Provider.allCases.map { .loginExpired($0) }
      + GuesthouseError.Tool.allCases.map { .toolMismatch(tool: $0) }
      + GuesthouseError.InvalidRequestReason.allCases.map { .invalidRequest($0) }
      + GuesthouseError.InvalidRuntimeReplyReason.allCases.map { .invalidRuntimeReply($0) }

    @Test(arguments: errors) func everyDomainErrorRetainsItsRecovery(error: GuesthouseError) {
        let state = RecoveryPresentation(error: error)
        #expect(!state.message.isEmpty && !state.actions.isEmpty)
        #expect(state.actions == error.recoveryActions)
        if state.outcomeUnknown { #expect(!state.actions.contains(.retry)) }
    }
    @Test func transportUncertaintyNeverOffersRetryWithoutInventingAnOperationID() {
        let failure = RuntimeSessionFailure(cause: .connectionLost, mayHaveMutated: true)
        let state = RecoveryPresentation(failure: .interrupted(failure))
        #expect(state.outcomeUnknown && !state.actions.contains(.retry) && state.actions.contains(.inspectState))
        #expect(failure.operationID == nil)
    }
    @Test(arguments: ProgressPhase.Kind.allCases) func progressKeepsNamedMeasuredAndProtectedPhases(kind: ProgressPhase.Kind) {
        let state = OperationProgressPresentation(phase: .init(kind: kind, fraction: 0.25, cancelable: false))
        #expect(!state.title.isEmpty && state.phase?.fraction == 0.25 && state.requiresCancellationConfirmation)
        #expect(OperationProgressPresentation(phase: nil).requiresCancellationConfirmation)
        #expect(!OperationProgressPresentation(phase: .init(kind: kind)).requiresCancellationConfirmation)
    }
    @Test func retryAfterPreStartInspectionFailureChecksAgainBeforeSending() async {
        let fake = FakeRuntimeBackend(), environment = DevelopmentEnvironment(name: "Dev Mac")
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let model = AppModel(backend: fake); await model.checkEnvironments().value
        await fake.script("listEnvironments", .disconnect())
        await model.startEnvironment(environment.id)?.value
        #expect(!model.canStart(environment.id) && model.canRetryStart(environment.id))
        #expect(await fake.receivedRequests.allSatisfy { if case .startEnvironment = $0 { false } else { true } })
        await fake.script("listEnvironments", .succeed())
        await fake.script("startEnvironment", .succeed(status: .init(environmentID: environment.id, vm: .running, readiness: .checking)))
        let retry = model.retryStart(environment.id)
        #expect(retry != nil && model.retryStart(environment.id) == nil)
        await retry?.value
        #expect(model.startFailure == nil && model.statuses[environment.id]?.vm == .running)
        #expect(await fake.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }.count == 1)
    }
    @Test func missingEnvironmentRetainsDiagnosticsAndInspectionRecovery() async {
        let environment = DevelopmentEnvironment(name: "Dev Mac"), operation = OperationID(), fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let event = DiagnosticEvent(operation: .startEnvironment, outcome: .started, operationID: operation.uuid, environmentID: environment.id)
        let backend = DiagnosticStartBackend(fake: fake, events: [.accepted(operation), .diagnostic(event), .completed(operation)], emptyInventoryOnStart: true)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        await model.startEnvironment(environment.id)?.value
        #expect(model.environments.isEmpty && model.startingEnvironment == environment.id)
        #expect(model.startDiagnostics.records.map(\.event) == [event])
        #expect(model.startFailure == .notRunning)
        #expect(model.startFailure?.recoveryActions.contains(.inspectState) == true)
    }
    @Test(arguments: [false, true])
    func diagnosticsAreBoundedAndRejectForeignEnvironment(foreign: Bool) async {
        let environment = DevelopmentEnvironment(name: "Dev Mac"), operation = OperationID(), fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let diagnostic = DiagnosticEvent(operation: .startEnvironment, outcome: .started, operationID: operation.uuid,
            environmentID: foreign ? EnvironmentID() : environment.id)
        let backend = DiagnosticStartBackend(fake: fake, events: [.accepted(operation)]
            + Array(repeating: .diagnostic(diagnostic), count: 300) + [.completed(operation)])
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        await model.startEnvironment(environment.id)?.value
        #expect(model.startDiagnostics.records.count == (foreign ? 0 : 256))
        #expect(model.startDiagnostics.discardedCount == (foreign ? 0 : 44))
        #expect(model.sessionDiagnostics.records.count == (foreign ? 0 : 300))
        if foreign {
            #expect(model.startFailure == .interrupted(.init(cause: .malformedResponse, operationID: operation, mayHaveMutated: true)))
            model.dismissStartFailure()
            #expect(model.startFailureDismissed && model.startFailure != nil && !model.canStart(environment.id))
            #expect(!model.canRetryStart(environment.id) && model.retryStart(environment.id) == nil)
        }
    }
}

private nonisolated struct DiagnosticStartBackend: RuntimeBackend {
    var allowsEnvironmentStart: Bool { fake.allowsEnvironmentStart }
    let fake: FakeRuntimeBackend
    let events: [RuntimeEvent]
    var emptyInventoryOnStart = false
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { fake.connectionInterruptions }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        guard case .startEnvironment = request else { return fake.send(request) }
        return AsyncThrowingStream { continuation in
            Task {
                if emptyInventoryOnStart { await fake.setEnvironmentInventory(.available([])) }
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}
