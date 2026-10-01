import Foundation
import GuesthouseCore
import Observation
import Synchronization
import Testing
@testable import Guesthouse

@MainActor @Suite(.timeLimit(.minutes(1))) struct StartCancellationTests {
    let environment = DevelopmentEnvironment(name: "Dev Mac"), operation = OperationID()
    func configured(_ fake: FakeRuntimeBackend) async {
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .ready))
    }
    @Test func cancellationBeforeInspectionFinishesNeverSendsStart() async {
        let fake = FakeRuntimeBackend(); await configured(fake)
        let model = AppModel(backend: fake); await model.checkEnvironments().value
        let task = model.startEnvironment(environment.id)
        model.cancelStart(); model.cancelStart()
        await task?.value
        #expect(model.startFailure == .runtime(.canceled))
        #expect(await fake.receivedRequests.allSatisfy { request in
            switch request { case .startEnvironment, .cancelOperation: false; default: true }
        })
    }
    @Test(arguments: [false, true])
    func cancellationWaitsForAcceptanceAndAcknowledgementDoesNotSettleTarget(refused: Bool) async throws {
        let backend = CancellationBackend(operation: operation); await configured(backend.fake)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        let task = try #require(model.startEnvironment(environment.id))
        var starts = backend.started.makeAsyncIterator(), cancels = backend.canceled.makeAsyncIterator()
        _ = await starts.next()
        // Request arrived, but no accepted ID exists yet. Keep observing instead of guessing.
        model.cancelStart(); model.cancelStart()
        #expect(backend.cancelTargets.isEmpty && model.startOperationID == nil)
        backend.accept()
        _ = await cancels.next()
        #expect(backend.cancelTargets == [operation])
        #expect(model.isStarting && model.startFailure == nil && !model.canStart(environment.id))
        let failure = GuesthouseError.invalidRequest(.unsupportedOperation)
        let (changed, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish() }
        withObservationTracking { _ = model.startCancellationReplyReceived } onChange: { signal.yield(()) }
        backend.answerCancel(refused ? .failed(OperationID(), failure) : .completed(OperationID()))
        var observations = changed.makeAsyncIterator(); _ = await observations.next()
        #expect(model.startCancellationReplyReceived)
        #expect(model.startCancellationFailure == (refused ? .runtime(failure) : nil))
        // Even a successful acknowledgment never ends the original target stream.
        #expect(model.isStarting && model.startFailure == nil)
        backend.finishTarget(.failed(operation, .canceled))
        await task.value
        #expect(!model.isStarting && model.startFailure == .runtime(.canceled))
        #expect(backend.cancelTargets == [operation])
    }
}

private nonisolated final class CancellationBackend: RuntimeBackend {
    let fake = FakeRuntimeBackend(), operation: OperationID
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { fake.connectionInterruptions }
    let started: AsyncStream<Void>, canceled: AsyncStream<Void>
    private let startSignal: AsyncStream<Void>.Continuation, cancelSignal: AsyncStream<Void>.Continuation
    private let target = Mutex<AsyncThrowingStream<RuntimeEvent, any Error>.Continuation?>(nil)
    private let cancelReply = Mutex<AsyncThrowingStream<RuntimeEvent, any Error>.Continuation?>(nil)
    private let targets = Mutex<[OperationID]>([])
    var cancelTargets: [OperationID] { targets.withLock { $0 } }
    init(operation: OperationID) {
        self.operation = operation
        (started, startSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (canceled, cancelSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    deinit { startSignal.finish(); cancelSignal.finish() }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        switch request {
        case .startEnvironment:
            let (events, reply) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
            target.withLock { $0 = reply }; startSignal.yield(()); return events
        case .cancelOperation(let id):
            targets.withLock { $0.append(id) }
            let (events, reply) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
            cancelReply.withLock { $0 = reply }; cancelSignal.yield(()); return events
        default: return fake.send(request)
        }
    }
    func accept() { target.withLock { $0 }?.yield(.accepted(operation)) }
    func answerCancel(_ event: RuntimeEvent) {
        let reply = cancelReply.withLock { state in defer { state = nil }; return state }
        reply?.yield(event); reply?.finish()
    }
    func finishTarget(_ event: RuntimeEvent) {
        let reply = target.withLock { state in defer { state = nil }; return state }
        reply?.yield(event); reply?.finish()
    }
}
