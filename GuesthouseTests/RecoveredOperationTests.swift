import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import Guesthouse

@MainActor @Suite(.timeLimit(.minutes(1)))
struct RecoveredOperationTests {
    let recovered = DevelopmentEnvironment(name: "Recovered Mac")
    let idle = DevelopmentEnvironment(name: "Idle Mac")
    let operation = OperationID()

    private func configured() async -> FakeRuntimeBackend {
        let backend = FakeRuntimeBackend()
        await backend.setEnvironmentInventory(.available([recovered, idle]))
        await backend.setStatus(.init(environmentID: recovered.id, vm: .stopped,
            readiness: .checking, inFlightOperation: operation))
        await backend.setStatus(.init(environmentID: idle.id, vm: .stopped, readiness: .checking))
        return backend
    }

    @Test func failedCheckAndMissingCardCannotForgetARecoveredOperation() async {
        let backend = await configured(), model = AppModel(backend: backend)
        await model.checkEnvironments().value
        #expect(!model.canStart(idle.id))
        await backend.script("listEnvironments", .fail(error: .unauthorizedCaller))
        await model.checkEnvironments().value
        #expect(model.checkState == .unavailable(.unauthorizedCaller) && model.statuses.isEmpty)
        await backend.script("listEnvironments", .succeed())
        await backend.setEnvironmentInventory(.available([idle]))
        await model.checkEnvironments().value
        #expect(Array(await backend.receivedRequests.suffix(3)) == [
            .listEnvironments, .environmentStatus(idle.id), .environmentStatus(recovered.id)])
        #expect(!model.canStart(idle.id) && model.startEnvironment(idle.id) == nil)
        let decisions = RecoveredQuitDecisions()
        let quit = QuitCoordinator(model: model, terminationDecision: decisions.record)
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(.unsettled(operation)) && decisions.values.isEmpty)
        #expect(!quit.canForceStop)
    }

    @Test func uncertainStatusWithoutAnOperationKeepsThePreviouslyObservedIdentity() async {
        let backend = await configured(), model = AppModel(backend: backend)
        await model.checkEnvironments().value
        model.connectionInterrupted(.connectionLost)
        await backend.setStatus(.init(environmentID: recovered.id,
            vm: .uncertain(reason: .inspectionFailed), readiness: .checking))
        await model.checkEnvironments().value
        let decisions = RecoveredQuitDecisions()
        let quit = QuitCoordinator(model: model, terminationDecision: decisions.record)
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(.unsettled(operation)) && decisions.values.isEmpty)
        #expect(!model.canStart(idle.id))
    }

    @Test func aValidPartialObservationSurvivesTheFailureOfAnotherStatusQuery() async throws {
        let fake = await configured(), backend = HeldRecoveredCheck(fake: fake)
        backend.holdNextStatus(idle.id)
        let model = AppModel(backend: backend), check = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator(); try #require(await sent.next() != nil)
        #expect(model.recoveredOperations == [recovered.id: operation])
        #expect(model.statuses.isEmpty && model.environments.isEmpty)
        backend.answer([.status(.init(environmentID: EnvironmentID(), vm: .stopped, readiness: .checking))])
        await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
        await fake.setEnvironmentInventory(.available([idle]))
        await model.checkEnvironments().value
        #expect(model.recoveredOperations == [recovered.id: operation] && !model.canStart(idle.id))
        #expect(Array(await fake.receivedRequests.suffix(3)) == [
            .listEnvironments, .environmentStatus(idle.id), .environmentStatus(recovered.id)])
    }

    @Test(arguments: [false, true])
    func aLaterQueryRefusalKeepsDiagnosticsSeparateFromRecoveredOwnership(retired: Bool) async throws {
        let fake = await configured(), backend = HeldRecoveredCheck(fake: fake)
        backend.holdNextStatus(idle.id)
        let query = OperationID(), model = AppModel(backend: backend), check = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator(); try #require(await sent.next() != nil)
        #expect(model.recoveredOperations == [recovered.id: operation])
        if retired { model.connectionInterrupted(.connectionLost) }
        backend.answer([.failed(query, .guestNotReachable(idle.id))]); await check.value
        #expect(model.recoveredOperations == [recovered.id: operation])
        #expect(model.statuses.isEmpty && model.environments.isEmpty && !model.canStart(idle.id))
        #expect(model.startEnvironment(idle.id) == nil)
        let event = try #require(model.sessionDiagnostics.records.first?.event)
        #expect(model.sessionDiagnostics.records.count == 1 && event.environmentID == idle.id)
        if retired {
            #expect(model.checkState == .interrupted(.connectionLost))
            #expect(event.origin == .appObservation && event.outcome == .observationFailed(.connectionLost))
            #expect(event.operationID != operation.uuid && event.operationID != query.uuid)
        } else {
            #expect(model.checkState == .unavailable(.guestNotReachable(idle.id)))
            #expect(event == DiagnosticEvent(operation: .inspectEnvironment,
                outcome: .operationFailed(.guestNotReachable(idle.id)), operationID: query.uuid, environmentID: idle.id))
        }
        #expect(await fake.receivedRequests == [.listEnvironments, .environmentStatus(recovered.id)])
    }

    @Test(arguments: [EnvironmentStatus.VMState.stopped, .running])
    func completeListedIdleInspectionCanClearTheObligation(vm: EnvironmentStatus.VMState) async {
        let backend = await configured(), model = AppModel(backend: backend)
        await model.checkEnvironments().value
        await backend.setStatus(.init(environmentID: recovered.id, vm: vm, readiness: .checking))
        await model.checkEnvironments().value
        #expect(model.recoveredOperations.isEmpty && model.canStart(idle.id))
        #expect(await backend.receivedRequests.allSatisfy { request in
            switch request { case .listEnvironments, .environmentStatus: true; default: false }
        }) // Inspection never cancels, stops or retries the recovered operation.
    }

    @Test(arguments: [EnvironmentStatus.VMState.notFound, .stopped, .running, .uncertain(reason: .inspectionFailed)])
    func anUnlistedTargetStillNeedsMetadataReconciliation(vm: EnvironmentStatus.VMState) async {
        let backend = await configured(), model = AppModel(backend: backend)
        await model.checkEnvironments().value
        await backend.setEnvironmentInventory(.available([idle]))
        await backend.setStatus(.init(environmentID: recovered.id, vm: vm, readiness: .checking))
        await model.checkEnvironments().value
        #expect(model.recoveredOperations == [recovered.id: operation] && !model.canStart(idle.id))
        let decisions = RecoveredQuitDecisions()
        let quit = QuitCoordinator(model: model, terminationDecision: decisions.record)
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(.unsettled(operation)) && decisions.values.isEmpty && !quit.canForceStop)
    }

    @Test func aPartialIdleReadCannotClearTheObligationBeforeTheWholeCheckSucceeds() async throws {
        let fake = await configured(), backend = HeldRecoveredCheck(fake: fake), model = AppModel(backend: backend)
        await model.checkEnvironments().value
        await fake.setStatus(.init(environmentID: recovered.id, vm: .stopped, readiness: .checking))
        backend.holdNextStatus(idle.id)
        let check = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator(); try #require(await sent.next() != nil)
        backend.answer([]); await check.value
        #expect(model.recoveredOperations == [recovered.id: operation] && model.statuses.isEmpty)
        await model.checkEnvironments().value
        #expect(model.recoveredOperations.isEmpty && model.canStart(idle.id))
    }

    @Test func aRetiredCheckCannotClearAPreviouslyObservedIdentity() async throws {
        let fake = await configured(), backend = HeldRecoveredCheck(fake: fake), model = AppModel(backend: backend)
        await model.checkEnvironments().value
        backend.holdNextStatus(recovered.id)
        let check = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator(); try #require(await sent.next() != nil)
        model.connectionInterrupted(.connectionLost)
        backend.answer([.status(.init(environmentID: recovered.id, vm: .stopped, readiness: .checking))])
        await check.value
        #expect(model.checkState == .interrupted(.connectionLost) && model.statuses.isEmpty)
        #expect(model.recoveredOperations == [recovered.id: operation])
    }

    @Test(arguments: [false, true])
    func aRetiredOrCanceledCheckCannotDiscoverAnOperation(cancel: Bool) async throws {
        let fake = await configured(), backend = HeldRecoveredCheck(fake: fake)
        backend.holdNextStatus(recovered.id)
        let model = AppModel(backend: backend), check = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator(); try #require(await sent.next() != nil)
        model.connectionInterrupted(.connectionLost)
        if cancel { check.cancel() }
        backend.answer([.status(.init(environmentID: recovered.id, vm: .running,
            readiness: .checking, inFlightOperation: operation))])
        await check.value
        #expect(model.recoveredOperations.isEmpty && model.statuses.isEmpty)
    }

    @Test func malformedStatusStreamCannotMintARecoveredIdentity() async throws {
        let fake = await configured(), backend = HeldRecoveredCheck(fake: fake)
        backend.holdNextStatus(recovered.id)
        let model = AppModel(backend: backend), check = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator(); try #require(await sent.next() != nil)
        let status = EnvironmentStatus(environmentID: recovered.id, vm: .running,
            readiness: .checking, inFlightOperation: operation)
        backend.answer([.status(status), .status(status)]); await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
        #expect(model.recoveredOperations.isEmpty && model.statuses.isEmpty)
    }

    @Test func aNewlyObservedOperationReplacesThePriorIdentityWithoutAllowingWork() async {
        let backend = await configured(), model = AppModel(backend: backend), next = OperationID()
        await model.checkEnvironments().value
        await backend.setStatus(.init(environmentID: recovered.id, vm: .running,
            readiness: .checking, inFlightOperation: next))
        await model.checkEnvironments().value
        #expect(model.recoveredOperations == [recovered.id: next] && !model.canStart(idle.id))
        let decisions = RecoveredQuitDecisions()
        let quit = QuitCoordinator(model: model, terminationDecision: decisions.record)
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(.unsettled(next)) && decisions.values.isEmpty)
    }
}

/// One held status reply; all other requests use the existing fake. No timing-based polling.
private nonisolated final class HeldRecoveredCheck: RuntimeBackend {
    private struct State {
        var target: EnvironmentID?
        var reply: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation?
    }
    private let state = Mutex(State())
    let fake: FakeRuntimeBackend
    var allowsEnvironmentStart: Bool { fake.allowsEnvironmentStart }
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { fake.connectionInterruptions }
    let sent: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    init(fake: FakeRuntimeBackend) {
        self.fake = fake
        (sent, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    deinit { signal.finish() }
    func holdNextStatus(_ id: EnvironmentID) { state.withLock { $0.target = id } }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        let held = state.withLock { state in
            guard case .environmentStatus(let id) = request, state.target == id else { return false }
            state.target = nil; return true
        }
        guard held else { return fake.send(request) }
        let (events, reply) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        state.withLock { $0.reply = reply }; signal.yield(()); return events
    }
    func answer(_ events: [RuntimeEvent]) {
        let reply = state.withLock { state in defer { state.reply = nil }; return state.reply }
        for event in events { reply?.yield(event) }; reply?.finish()
    }
}

@MainActor private final class RecoveredQuitDecisions {
    var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}
