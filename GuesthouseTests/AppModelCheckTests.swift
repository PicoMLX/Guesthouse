import Foundation
import GuesthouseCore
import Observation
import Synchronization
import Testing
@testable import Guesthouse

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppModelCheckTests {
    @Test func checksSavedRecordsWithoutUpgradingUncertainStatusToReady() async {
        let backend = FakeRuntimeBackend(), environment = DevelopmentEnvironment(name: "Development Mac")
        let status = EnvironmentStatus(environmentID: environment.id,
            vm: .uncertain(reason: .ownershipUnproven), readiness: .checking)
        await backend.setEnvironmentInventory(.available([environment]))
        await backend.setStatus(status)
        let model = AppModel(backend: backend)
        #expect(model.checkState == .checkingEnvironment)
        await model.checkEnvironments().value
        #expect(model.checkState == .checked)
        #expect(model.environments == [environment] && model.statuses == [environment.id: status])
        #expect(await backend.receivedRequests == [.listEnvironments, .environmentStatus(environment.id)])
    }

    @Test(arguments: [RuntimeSavedStateStatus.loading, .repairRequired, .incompatible, .unavailable])
    func unavailableInventoryIsNeverAnEmptySuccessfulCheck(state: RuntimeSavedStateStatus) async {
        let backend = FakeRuntimeBackend()
        await backend.setEnvironmentInventory(.unavailable(state))
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        #expect(model.checkState == .metadataUnavailable(state) && model.statuses.isEmpty)
        #expect(await backend.receivedRequests == [.listEnvironments])
        model.connectionInterrupted(.connectionLost)
        #expect(model.checkState == .metadataUnavailable(state))
    }

    @Test func idleConnectionLossClearsStatusAndDoesNotRetry() async {
        let backend = FakeRuntimeBackend(), environment = DevelopmentEnvironment(name: "Saved Mac")
        await backend.setEnvironmentInventory(.available([environment]))
        await backend.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        withObservationTracking { _ = model.checkState } onChange: { changed.yield(()) }
        await backend.simulateConnectionInterruption()
        var iterator = changes.makeAsyncIterator()
        _ = await iterator.next()
        #expect(model.checkState == .interrupted(.connectionLost))
        #expect(model.statuses.isEmpty && model.environments == [environment])
        #expect(await backend.receivedRequests.count == 2)
        await model.checkEnvironments().value
        #expect(model.checkState == .checked && model.statuses.count == 1)
    }

    @Test func repeatedChecksJoinAndLateSuccessAfterLossCannotPublish() async {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let first = model.checkEnvironments(), joined = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator()
        _ = await sent.next()
        #expect(backend.requests == [.listEnvironments] && model.isChecking)
        model.connectionInterrupted(.connectionLost)
        backend.answer([.environments(.available([]))])
        await first.value
        await joined.value
        #expect(model.checkState == .interrupted(.connectionLost) && !model.isChecking)
        #expect(model.statuses.isEmpty && backend.requests.count == 1)
    }

    @Test(arguments: [[], [.completed(OperationID())],
                     [.environments(.available([])), .environments(.available([]))],
                     [.environments(.unavailable(.loaded))]] as [[RuntimeEvent]])
    func malformedInventoryDoesNotPublishSuccess(events: [RuntimeEvent]) async {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let check = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator()
        _ = await sent.next()
        backend.answer(events)
        await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
    }

    @Test func foreignStatusAndPartialResultsAreNotPublished() async {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let check = model.checkEnvironments(), environment = DevelopmentEnvironment(name: "Saved Mac")
        let second = DevelopmentEnvironment(name: "Another Mac")
        var sent = backend.sent.makeAsyncIterator()
        _ = await sent.next()
        backend.answer([.environments(.available([environment, second]))])
        _ = await sent.next()
        backend.answer([.status(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))])
        _ = await sent.next()
        backend.answer([.status(.init(environmentID: EnvironmentID(), vm: .running, readiness: .ready))])
        await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
        #expect(model.environments.isEmpty && model.statuses.isEmpty)
    }

    @Test func cancellationBeforeTheCheckStartsSendsNothingAndAllowsAnotherCheck() async {
        let backend = FakeRuntimeBackend()
        let checkedModel = AppModel(backend: backend)
        let task = checkedModel.checkEnvironments()
        task.cancel()
        await task.value
        #expect(checkedModel.checkState == .unavailable(.canceled) && !checkedModel.isChecking)
        #expect(await backend.receivedRequests.isEmpty)
        await checkedModel.checkEnvironments().value
        #expect(checkedModel.checkState == .checked)
    }

    @Test func failedCheckDoesNotStartAnAutomaticReconnectLoop() async {
        let backend = FakeRuntimeBackend()
        let checkedModel = AppModel(backend: backend)
        await backend.script("listEnvironments", .disconnect())
        await checkedModel.checkEnvironments().value
        #expect(checkedModel.checkState == .interrupted(.connectionLost))
        #expect(await backend.receivedRequests == [.listEnvironments])
    }

    @Test func typedFailureKeepsRecoveryAndDoesNotRetryOnFollowingRetirement() async {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .fail(error: .unauthorizedCaller))
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        model.connectionInterrupted(.connectionLost)
        #expect(model.checkState == .unavailable(.unauthorizedCaller))
        #expect(await backend.receivedRequests == [.listEnvironments])
    }
}

/// Controlled asynchronous replies without timing-based waits or native service access.
private nonisolated final class HeldCheckBackend: RuntimeBackend {
    struct State {
        var requests: [RuntimeRequest] = []
        var reply: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation?
    }
    private let state = Mutex(State())
    let connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause>
    private let interruptionSink: AsyncStream<RuntimeSessionFailure.Cause>.Continuation
    let sent: AsyncStream<Void>
    private let sendSignal: AsyncStream<Void>.Continuation
    var requests: [RuntimeRequest] { state.withLock { $0.requests } }
    init() {
        (connectionInterruptions, interruptionSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (sent, sendSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    deinit { interruptionSink.finish(); sendSignal.finish() }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        let (stream, reply) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        state.withLock { $0.requests.append(request); $0.reply = reply }
        sendSignal.yield(())
        return stream
    }
    func answer(_ events: [RuntimeEvent]) {
        let reply = state.withLock { state in defer { state.reply = nil }; return state.reply }
        for event in events { reply?.yield(event) }
        reply?.finish()
    }
}
