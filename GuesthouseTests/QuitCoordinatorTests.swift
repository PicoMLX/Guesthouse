import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import Guesthouse

@MainActor @Suite(.timeLimit(.minutes(1)))
struct QuitCoordinatorTests {
    let environment = DevelopmentEnvironment(name: "Development Mac")
    let operation = OperationID()

    private func configuredFake(vm: EnvironmentStatus.VMState = .running, busy: OperationID? = nil) async -> FakeRuntimeBackend {
        let backend = FakeRuntimeBackend()
        await backend.setEnvironmentInventory(.available([environment]))
        await backend.setStatus(.init(environmentID: environment.id, vm: vm, readiness: .checking, inFlightOperation: busy))
        return backend
    }

    @Test func gracefulStopRequiresTerminalAndFreshStoppedInspectionBeforeQuit() async throws {
        let backend = await configuredFake(), decision = Decision()
        await backend.script("stopEnvironment", .succeed(status: .init(environmentID: environment.id, vm: .stopped, readiness: .checking)))
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        #expect(!quit.requestQuit())
        let work = try #require(quit.confirmStopAndQuit())
        #expect(quit.confirmStopAndQuit() == nil)
        await work.value
        #expect(quit.flow == .terminating && decision.values == [true])
        #expect(await backend.receivedRequests == [.listEnvironments, .environmentStatus(environment.id),
            .stopEnvironment(environment.id, .graceful(deadline: .seconds(60))), .listEnvironments, .environmentStatus(environment.id)])
    }

    @Test func confirmedRefusalOffersForceOnlyForThatAttemptAndRechecksBeforeForcing() async throws {
        let backend = await configuredFake(), decision = Decision()
        await backend.script("stopEnvironment", .fail(error: .guestShutdownRefused(environment.id)))
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit()
        await quit.confirmStopAndQuit()?.value
        #expect(quit.canForceStop && decision.values.isEmpty)
        await backend.script("stopEnvironment", .succeed(status: .init(environmentID: environment.id, vm: .stopped, readiness: .checking)))
        await quit.forceStopAndQuit()?.value
        #expect(decision.values == [true])
        let requests = await backend.receivedRequests
        #expect(Array(requests.suffix(5)) == [.listEnvironments, .environmentStatus(environment.id),
            .stopEnvironment(environment.id, .force), .listEnvironments, .environmentStatus(environment.id)])
    }

    @Test(arguments: [false, true])
    func uncertainOwnershipOrUnsettledOperationNeverSignalsAStop(busy: Bool) async {
        let backend = await configuredFake(vm: busy ? .running : .uncertain(reason: .ownershipUnproven), busy: busy ? operation : nil)
        let decision = Decision()
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit()
        await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(busy ? .unsettled(operation) : .ownership(environment.id, .ownershipUnproven)))
        #expect(!quit.canForceStop && decision.values.isEmpty)
        #expect(await backend.receivedRequests == [.listEnvironments, .environmentStatus(environment.id)])
    }

    @Test func interruptedStopKeepsActualIdentityAndNeverOffersForce() async {
        let backend = await configuredFake(), decision = Decision()
        await backend.useOperationID(operation, forNext: "stopEnvironment")
        await backend.script("stopEnvironment", .disconnect())
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit()
        await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(.interrupted(.init(cause: .connectionLost, operationID: operation, mayHaveMutated: true))))
        #expect(!quit.canForceStop && decision.values.isEmpty)
    }

    @Test func completionWithoutConfirmedStoppedStateDoesNotTerminate() async {
        let backend = await configuredFake(), decision = Decision()
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit()
        await quit.confirmStopAndQuit()?.value
        #expect(quit.flow == .failed(.stillRunning) && decision.values.isEmpty && !quit.canForceStop)
    }

    @Test func oldGracefulFailureCannotAuthorizeForceInANewAttempt() async {
        let backend = await configuredFake(), decision = Decision()
        await backend.script("stopEnvironment", .fail(error: .guestShutdownRefused(environment.id)))
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit()
        await quit.confirmStopAndQuit()?.value
        #expect(quit.canForceStop)
        quit.cancelQuit()
        await backend.script("stopEnvironment", .fail(error: .runtimeIncompatible))
        _ = quit.requestQuit()
        await quit.confirmStopAndQuit()?.value
        #expect(!quit.canForceStop && quit.flow == .failed(.stop(.runtimeIncompatible)))
        #expect(decision.values == [false])
    }

    @Test func cancellationDuringProtectedStopWaitsForOutcomeAndMenuCheckCannotInterfere() async throws {
        let fake = await configuredFake(), backend = HeldStopBackend(fake: fake, operation: operation), decision = Decision()
        let model = AppModel(backend: backend), quit = QuitCoordinator(model: model, terminationDecision: decision.record)
        _ = quit.requestQuit()
        let work = try #require(quit.confirmStopAndQuit())
        var sent = backend.stopped.makeAsyncIterator()
        _ = await sent.next()
        // No phase yet is protected too: it is unsafe to lose an unaccepted stop's outcome.
        quit.cancelQuit()
        #expect(quit.cancelRequested && decision.values.isEmpty)
        await model.checkEnvironments().value
        #expect(await fake.receivedRequests == [.listEnvironments, .environmentStatus(environment.id)])
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        backend.finish()
        await work.value
        #expect(quit.flow == .idle && decision.values == [false])
    }

    @Test(arguments: [false, true])
    func refusalBeforeAcceptanceOrMissingTerminalNeverOffersForce(preacceptRefusal: Bool) async throws {
        let fake = await configuredFake(), backend = HeldStopBackend(fake: fake, operation: operation), decision = Decision()
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit()
        let work = try #require(quit.confirmStopAndQuit())
        var sent = backend.stopped.makeAsyncIterator()
        _ = await sent.next()
        backend.answer(preacceptRefusal ? [.failed(operation, .guestShutdownRefused(environment.id))] : [.accepted(operation)])
        await work.value
        #expect(!quit.canForceStop && decision.values.isEmpty)
        if !preacceptRefusal {
            #expect(quit.flow == .failed(.interrupted(.init(cause: .malformedResponse, operationID: operation, mayHaveMutated: true))))
        }
    }

    @Test func aNewRunningEnvironmentIsNeverForcedUsingAnotherEnvironmentsRefusal() async {
        let backend = await configuredFake(), decision = Decision(), second = DevelopmentEnvironment(name: "New Mac")
        await backend.script("stopEnvironment", .fail(error: .guestShutdownRefused(environment.id)))
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit()
        await quit.confirmStopAndQuit()?.value
        await backend.setEnvironmentInventory(.available([environment, second]))
        await backend.setStatus(.init(environmentID: second.id, vm: .running, readiness: .checking))
        // The deliberately foreign status on the second stop also must block termination.
        await backend.script("stopEnvironment", .succeed(status: .init(environmentID: environment.id, vm: .stopped, readiness: .checking)))
        await quit.forceStopAndQuit()?.value
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { true } else { false } }
        #expect(stops == [.stopEnvironment(environment.id, .graceful(deadline: .seconds(60))),
                          .stopEnvironment(environment.id, .force), .stopEnvironment(second.id, .graceful(deadline: .seconds(60)))])
        #expect(decision.values.isEmpty && !quit.canForceStop)
    }

    @Test func canceledQuitBeforeItsCheckStartsCannotResurrect() async {
        let backend = await configuredFake(), decision = Decision()
        let model = AppModel(backend: backend), quit = QuitCoordinator(model: model, terminationDecision: decision.record)
        _ = quit.requestQuit()
        let work = quit.confirmStopAndQuit()
        quit.cancelQuit()
        await work?.value
        await model.checkEnvironments().value
        #expect(quit.flow == .idle && decision.values == [false])
        #expect(await backend.receivedRequests.allSatisfy { request in
            switch request { case .listEnvironments, .environmentStatus: true; default: false }
        })
    }
}

@MainActor private final class Decision {
    var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}

private nonisolated final class HeldStopBackend: RuntimeBackend {
    let fake: FakeRuntimeBackend, operation: OperationID
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { fake.connectionInterruptions }
    let stopped: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let pending = Mutex<AsyncThrowingStream<RuntimeEvent, any Error>.Continuation?>(nil)
    init(fake: FakeRuntimeBackend, operation: OperationID) {
        self.fake = fake; self.operation = operation
        (stopped, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    deinit { signal.finish() }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        guard case .stopEnvironment = request else { return fake.send(request) }
        let (events, continuation) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        pending.withLock { $0 = continuation }
        signal.yield(())
        return events
    }
    func finish() { answer([.accepted(operation), .completed(operation)]) }
    func answer(_ events: [RuntimeEvent]) {
        let continuation = pending.withLock { state in defer { state = nil }; return state }
        for event in events { continuation?.yield(event) }
        continuation?.finish()
    }
}
