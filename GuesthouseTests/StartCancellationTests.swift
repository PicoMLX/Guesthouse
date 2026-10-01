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
        if refused {
            #expect(!model.startCancellationRequested)
            model.cancelStart()
            _ = await cancels.next()
            #expect(backend.cancelTargets == [operation, operation])
            backend.answerCancel(.completed(OperationID()))
        }
        backend.finishTarget(.failed(operation, .canceled))
        await task.value
        #expect(!model.isStarting && model.startFailure == .runtime(.canceled))
        #expect(backend.cancelTargets.count == (refused ? 2 : 1))
    }
    nonisolated enum UncertainReply: CaseIterable, Sendable { case unexpectedEvent, unknownOutcome, invalidReply, canceled }
    @Test(arguments: UncertainReply.allCases)
    func uncertainCancellationReplyDoesNotAuthorizeRetry(kind: UncertainReply) async throws {
        let backend = CancellationBackend(operation: operation); await configured(backend.fake)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        let task = try #require(model.startEnvironment(environment.id))
        var starts = backend.started.makeAsyncIterator(), cancels = backend.canceled.makeAsyncIterator()
        _ = await starts.next(); model.cancelStart(); backend.accept(); _ = await cancels.next()
        let (changed, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish() }
        withObservationTracking { _ = model.startCancellationReplyReceived } onChange: { signal.yield(()) }
        switch kind {
        case .unexpectedEvent: backend.answerCancel(.progress(OperationID(), .init(kind: .startingVM)))
        case .unknownOutcome: backend.answerCancel(.failed(OperationID(), .operationOutcomeUnknown(OperationID())))
        case .invalidReply: backend.answerCancel(.failed(OperationID(), .invalidRuntimeReply(.malformed)))
        case .canceled: backend.answerCancel(.failed(OperationID(), .canceled))
        }
        var observations = changed.makeAsyncIterator(); _ = await observations.next()
        #expect(model.startCancellationRequested && model.startCancellationFailure != nil)
        model.cancelStart()
        #expect(backend.cancelTargets == [operation] && model.isStarting)
        backend.finishTarget(.failed(operation, .canceled)); await task.value
    }
    @Test func targetTerminalWaitsForOutstandingCancellationReply() async throws {
        let backend = CancellationBackend(operation: operation); await configured(backend.fake)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        let task = try #require(model.startEnvironment(environment.id))
        var starts = backend.started.makeAsyncIterator(), cancels = backend.canceled.makeAsyncIterator()
        _ = await starts.next()
        model.cancelStart(); backend.accept(); _ = await cancels.next()
        let (changed, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish() }
        withObservationTracking { _ = model.startCanCancel } onChange: { signal.yield(()) }
        backend.finishTarget(.failed(operation, .canceled))
        var observations = changed.makeAsyncIterator(); _ = await observations.next()
        #expect(!model.startCanCancel && model.isStarting && !model.isChecking)
        #expect(!model.canStart(environment.id) && !model.startCancellationReplyReceived)
        backend.answerCancel(.completed(OperationID()))
        await task.value
        #expect(!model.isStarting && model.startCancellationReplyReceived)
    }
    @Test(arguments: [false, true])
    func thrownRefusalAllowsRetryOnlyBeforeAnyReply(answered: Bool) async {
        let backend = CancellationBackend(operation: operation)
        let task = Task { await StartOperation.cancel(operation, backend: backend) }
        var cancels = backend.canceled.makeAsyncIterator(); _ = await cancels.next()
        backend.throwCancel(GuesthouseError.invalidRequest(.tooManyInFlight), afterReply: answered)
        let result = await task.value
        #expect(result.failure == .runtime(.invalidRequest(.tooManyInFlight)))
        #expect(result.retryAllowed == !answered)
    }
    @Test(arguments: [false, true])
    func transportFailurePreservesCancellationUncertaintyWithoutInventingIdentity(answered: Bool) async throws {
        for failure in [RuntimeSessionFailure(cause: .connectionLost),
                        .init(cause: .protocolMismatch(service: 1), operationID: OperationID())] {
            let backend = CancellationBackend(operation: operation)
            let task = Task { await StartOperation.cancel(operation, backend: backend) }
            var cancels = backend.canceled.makeAsyncIterator(); _ = await cancels.next()
            backend.throwCancel(failure, afterReply: answered)
            let result = await task.value
            #expect(result.failure == .interrupted(failure.contextualized(mayHaveMutated: true)) && !result.retryAllowed)
            let presentation = RecoveryPresentation(failure: try #require(result.failure))
            #expect(presentation.outcomeUnknown && !presentation.actions.contains(.retry))
        }
    }
    @Test func cancellationFailureSurvivesSuccessfulStartAndFreshCheckUntilAcknowledged() async throws {
        let backend = CancellationBackend(operation: operation); await configured(backend.fake)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        let task = try #require(model.startEnvironment(environment.id))
        var starts = backend.started.makeAsyncIterator(), cancels = backend.canceled.makeAsyncIterator()
        _ = await starts.next(); model.cancelStart(); backend.accept(); _ = await cancels.next()
        backend.answerCancel(.failed(OperationID(), .invalidRequest(.unsupportedOperation)))
        await backend.fake.setStatus(.init(environmentID: environment.id, vm: .running, readiness: .ready))
        backend.finishTarget(.completed(operation)); await task.value
        #expect(model.startFailure == nil && !model.isStarting)
        #expect(model.startCancellationFailure == .runtime(.invalidRequest(.unsupportedOperation)))
        await model.checkEnvironments().value
        #expect(model.startCancellationFailure != nil)
        let other = DevelopmentEnvironment(name: "Second Mac")
        await backend.fake.setEnvironmentInventory(.available([environment, other]))
        await backend.fake.setStatus(.init(environmentID: other.id, vm: .stopped, readiness: .ready))
        await model.checkEnvironments().value
        #expect(!model.canStart(other.id) && model.startEnvironment(other.id) == nil)
        #expect(model.startCancellationFailure == .runtime(.invalidRequest(.unsupportedOperation)))
        model.dismissStartCancellationFailure()
        #expect(model.startCancellationFailure == nil && model.statuses[environment.id]?.vm == .running)
        #expect(model.canStart(other.id))
    }
}

private nonisolated final class CancellationBackend: RuntimeBackend {
    var allowsEnvironmentStart: Bool { fake.allowsEnvironmentStart }
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
    func throwCancel(_ error: any Error, afterReply: Bool) {
        let reply = cancelReply.withLock { state in defer { state = nil }; return state }
        if afterReply { reply?.yield(.completed(OperationID())) }
        reply?.finish(throwing: error)
    }
    func finishTarget(_ event: RuntimeEvent) {
        let reply = target.withLock { state in defer { state = nil }; return state }
        reply?.yield(event); reply?.finish()
    }
}
