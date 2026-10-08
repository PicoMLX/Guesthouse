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
        #expect(state.message.contains(error.recoveryMessage))
        for action in state.actions {
            let expected: Bool
            switch action { case .retry: expected = !state.outcomeUnknown; case .inspectState, .cancel: expected = true; default: expected = false }
            #expect(state.canPerform(action, canRetry: true, canInspect: true) == expected)
            if action == .retry || action == .inspectState { #expect(!state.canPerform(action, canRetry: false, canInspect: false)) }
        }
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
        let quit = QuitCoordinator(model: model) { if $0 { Issue.record("Missing target must not authorize Quit") } }
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(.check(.unavailable(.invalidRuntimeReply(.malformed)))))
    }
    @Test(arguments: [false, true])
    func missingTargetBeforeStartWasSentDoesNotRequireRuntimeReconciliation(quitWithoutInspecting: Bool) async {
        let environment = DevelopmentEnvironment(name: "Missing Mac"), other = DevelopmentEnvironment(name: "Other Mac")
        let fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let model = AppModel(backend: fake); await model.checkEnvironments().value
        // The cached card permits a click, but the mandatory pre-Start check loses the target.
        await fake.setEnvironmentInventory(.available([other]))
        await fake.setStatus(.init(environmentID: other.id, vm: .stopped, readiness: .checking))
        await fake.setStatus(.init(environmentID: environment.id, vm: .uncertain(reason: .inspectionFailed), readiness: .checking))
        await model.startEnvironment(environment.id)?.value
        #expect(model.startFailure == .stateChanged && !model.canStart(other.id))
        if !quitWithoutInspecting {
            await model.checkEnvironments().value
            #expect(model.startFailure == nil && model.startingEnvironment == nil && model.canStart(other.id))
        }
        var decisions: [Bool] = []
        let quit = QuitCoordinator(model: model) { decisions.append($0) }
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .terminating && decisions == [true])
        let requests = await fake.receivedRequests
        #expect(requests.allSatisfy { if case .startEnvironment = $0 { false } else { true } })
        #expect(requests.filter { $0 == .environmentStatus(environment.id) }.count == 1)
    }
    @Test(arguments: [EnvironmentStatus.VMState.stopped, .notFound, .running, .uncertain(reason: .inspectionFailed)], [false, true])
    func explicitInspectionQueriesMissingTargetBeforeResolvingItsFailure(state: EnvironmentStatus.VMState, busy: Bool) async {
        let environment = DevelopmentEnvironment(name: "Missing Mac"), other = DevelopmentEnvironment(name: "Other Mac")
        let operation = OperationID(), fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let backend = DiagnosticStartBackend(fake: fake, events: [.accepted(operation), .completed(operation)], emptyInventoryOnStart: true)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        await model.startEnvironment(environment.id)?.value
        await fake.setEnvironmentInventory(.available([other]))
        await fake.setStatus(.init(environmentID: other.id, vm: .stopped, readiness: .checking))
        await fake.setStatus(.init(environmentID: environment.id, vm: state, readiness: .checking, inFlightOperation: busy ? OperationID() : nil))
        await model.checkEnvironments().value
        let resolved = !busy && (state == .stopped || state == .notFound)
        #expect((model.startFailure == nil) == resolved && model.canStart(other.id) == resolved)
        #expect((RecoveryPresentation.missingEnvironmentGuidance(hasFailure: model.startFailure != nil, needsInspection: model.startNeedsInspection) == nil) == resolved)
        #expect(Array(await fake.receivedRequests.suffix(3)) == [.listEnvironments, .environmentStatus(other.id), .environmentStatus(environment.id)])
    }
    @Test func lostStartReplyBeforeAcceptanceStillRequiresMissingTargetInspection() async {
        let environment = DevelopmentEnvironment(name: "Missing Mac"), fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let backend = DiagnosticStartBackend(fake: fake, events: [], emptyInventoryOnStart: true)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        await model.startEnvironment(environment.id)?.value
        #expect(model.startNeedsInspection)
        #expect(model.startFailure == .interrupted(.init(cause: .malformedResponse, mayHaveMutated: true)))
        await fake.setStatus(.init(environmentID: environment.id, vm: .uncertain(reason: .inspectionFailed), readiness: .checking))
        await model.checkEnvironments().value
        #expect(model.startNeedsInspection && model.startFailure != nil)
        #expect(Array(await fake.receivedRequests.suffix(2)) == [.listEnvironments, .environmentStatus(environment.id)])
        var decisions: [Bool] = []
        let quit = QuitCoordinator(model: model) { decisions.append($0) }
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(.check(.unavailable(.invalidRuntimeReply(.malformed)))) && decisions.isEmpty)
    }
    @Test(arguments: [false, true], [false, true])
    func knownStartRefusalRequiresTargetReconciliationOnlyAfterAcceptance(local: Bool, accepted: Bool) async {
        let environment = DevelopmentEnvironment(name: "Missing Mac"), other = DevelopmentEnvironment(name: "Other Mac")
        let operation = OperationID(), fake = FakeRuntimeBackend(), error = GuesthouseError.invalidRequest(.tooManyInFlight)
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let backend = DiagnosticStartBackend(fake: fake,
            events: (accepted ? [.accepted(operation)] : []) + (local ? [] : [.failed(operation, error)]),
            emptyInventoryOnStart: true, localRejection: local ? error : nil)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        await model.startEnvironment(environment.id)?.value
        #expect(model.startFailure == .runtime(error) && model.startNeedsInspection == accepted)
        await fake.setEnvironmentInventory(.available([other]))
        await fake.setStatus(.init(environmentID: other.id, vm: .stopped, readiness: .checking))
        await fake.setStatus(.init(environmentID: environment.id, vm: .uncertain(reason: .inspectionFailed), readiness: .checking))
        await model.checkEnvironments().value
        #expect((model.startFailure == nil) == !accepted && model.canStart(other.id) == !accepted)
        #expect(await fake.receivedRequests.filter { $0 == .environmentStatus(environment.id) }.count == (accepted ? 3 : 2))
        var decisions: [Bool] = []
        let quit = QuitCoordinator(model: model) { decisions.append($0) }
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect((quit.flow == .terminating) == !accepted && decisions == (accepted ? [] : [true]))
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
        #expect(model.startDiagnostics.records.count == (foreign ? 1 : 256))
        #expect(model.startDiagnostics.discardedCount == (foreign ? 0 : 44))
        #expect(model.sessionDiagnostics.records.count == (foreign ? 1 : 300))
        if foreign {
            #expect(model.sessionDiagnostics.records.first?.event == DiagnosticEvent(operation: .startEnvironment,
                outcome: .operationFailed(.operationOutcomeUnknown(operation)), operationID: operation.uuid, environmentID: environment.id))
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
    var localRejection: GuesthouseError?
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { fake.connectionInterruptions }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        guard case .startEnvironment = request else { return fake.send(request) }
        return AsyncThrowingStream { continuation in
            Task {
                if emptyInventoryOnStart { await fake.setEnvironmentInventory(.available([])) }
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: localRejection)
            }
        }
    }
}
