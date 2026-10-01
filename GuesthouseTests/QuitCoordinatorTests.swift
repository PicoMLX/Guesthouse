import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import Guesthouse

@MainActor @Suite(.timeLimit(.minutes(1)))
struct QuitCoordinatorTests {
    let environment = DevelopmentEnvironment(name: "Development Mac")
    let operation = OperationID()
    let instance = UUID()

    private func configuredFake(vm: EnvironmentStatus.VMState = .running, busy: OperationID? = nil) async -> FakeRuntimeBackend {
        let backend = FakeRuntimeBackend()
        await backend.setEnvironmentInventory(.available([environment]))
        await backend.setStatus(.init(environmentID: environment.id, vm: vm, readiness: .checking, inFlightOperation: busy, runtimeInstanceID: instance))
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

    @Test(arguments: [false, true])
    func confirmedRefusalOffersForceOnlyForThatAttemptAndRechecksBeforeForcing(stoppedBeforeConsent: Bool) async throws {
        let backend = await configuredFake(), decision = Decision()
        await backend.script("stopEnvironment", .fail(error: .guestShutdownRefused(environment.id)))
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit()
        await quit.confirmStopAndQuit()?.value
        #expect(quit.canForceStop && decision.values.isEmpty)
        if stoppedBeforeConsent {
            await backend.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
            await quit.inspectBeforeContinuing()?.value
            #expect(quit.flow == .confirming && !quit.canForceStop && decision.values.isEmpty)
            return
        }
        await backend.script("stopEnvironment", .succeed(status: .init(environmentID: environment.id, vm: .stopped, readiness: .checking)))
        await quit.forceStopAndQuit()?.value
        #expect(decision.values == [true])
        let requests = await backend.receivedRequests
        #expect(Array(requests.suffix(5)) == [.listEnvironments, .environmentStatus(environment.id),
            .stopEnvironment(environment.id, .force(expectedInstanceID: instance)), .listEnvironments, .environmentStatus(environment.id)])
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
                          .stopEnvironment(environment.id, .force(expectedInstanceID: instance)), .stopEnvironment(second.id, .graceful(deadline: .seconds(60)))])
        #expect(decision.values.isEmpty && !quit.canForceStop)
    }

    @Test(arguments: [false, true])
    func freshInspectionFindsNewTargetsAndCancellationBetweenStopsAlwaysCompletes(cancel: Bool) async throws {
        let fake = await configuredFake(), second = DevelopmentEnvironment(name: "Discovered Mac"), decision = Decision()
        let backend = HeldStopBackend(fake: fake, operation: operation, holdInventory: 2)
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit(); let work = try #require(quit.confirmStopAndQuit())
        var stops = backend.stopped.makeAsyncIterator(), inspections = backend.inspected.makeAsyncIterator()
        _ = await stops.next()
        await fake.setEnvironmentInventory(.available([environment, second]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        await fake.setStatus(.init(environmentID: second.id, vm: .running, readiness: .checking))
        backend.finish()
        _ = await inspections.next()
        #expect(quit.flow == .checking)
        if cancel { quit.cancelQuit(); #expect(decision.values == [false]) }
        backend.answerInventory([environment, second])
        if !cancel {
            _ = await stops.next()
            await fake.setStatus(.init(environmentID: second.id, vm: .stopped, readiness: .checking))
            backend.finish()
        }
        await work.value
        #expect(quit.flow == (cancel ? .idle : .terminating))
        #expect(decision.values == [!cancel])
        #expect(backend.stopRequests == (cancel ? [environment] : [environment, second]).map {
            .stopEnvironment($0.id, .graceful(deadline: .seconds(60)))
        })
    }

    @Test func postRefusalInspectionMustFinishAndProveOwnershipBeforeForceIsOffered() async throws {
        let fake = await configuredFake(), backend = HeldStopBackend(fake: fake, operation: operation, holdInventory: 2)
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: { _ in })
        _ = quit.requestQuit(); let work = try #require(quit.confirmStopAndQuit())
        var stops = backend.stopped.makeAsyncIterator(), inspections = backend.inspected.makeAsyncIterator()
        _ = await stops.next()
        backend.answer([.accepted(operation), .failed(operation, .guestShutdownRefused(environment.id))])
        _ = await inspections.next()
        #expect(quit.flow == .checking && !quit.canForceStop)
        await fake.setStatus(.init(environmentID: environment.id, vm: .uncertain(reason: .ownershipUnproven), readiness: .checking))
        backend.answerInventory([environment])
        await work.value
        #expect(quit.flow == .failed(.ownership(environment.id, .ownershipUnproven)) && !quit.canForceStop)
    }
    @Test(arguments: [false, true])
    func terminalStopFailureRemainsExportableWhenPostRefusalInspectionFails(queryRefusal: Bool) async throws {
        let fake = await configuredFake(), backend = HeldStopBackend(fake: fake, operation: operation), decision = Decision()
        let model = AppModel(backend: backend), quit = QuitCoordinator(model: model, terminationDecision: decision.record)
        _ = quit.requestQuit(); let work = try #require(quit.confirmStopAndQuit())
        var stops = backend.stopped.makeAsyncIterator(); _ = await stops.next()
        await fake.script("listEnvironments", queryRefusal ? .fail(error: .unauthorizedCaller) : .disconnect())
        backend.answer([.accepted(operation), .failed(operation, .guestShutdownRefused(environment.id))])
        await work.value
        #expect(quit.flow == .failed(.check(queryRefusal ? .unavailable(.unauthorizedCaller) : .interrupted(.connectionLost))))
        #expect(!quit.canForceStop && decision.values.isEmpty)
        let error = GuesthouseError.guestShutdownRefused(environment.id)
        let expected = DiagnosticEvent(operation: .stopEnvironment, outcome: .operationFailed(error),
            operationID: operation.uuid, environmentID: environment.id)
        #expect(model.sessionDiagnostics.records.first?.event == expected)
        #expect(model.sessionDiagnostics.records.count == 2)
        if queryRefusal {
            #expect(model.sessionDiagnostics.records.last?.event.operation == .inspectEnvironment)
            #expect(model.sessionDiagnostics.records.last?.event.outcome == .operationFailed(.unauthorizedCaller))
        }
        let export = try DiagnosticsExportBuilder.build(log: model.sessionDiagnostics, environmentIDs: [environment.id])
        let text = String(decoding: try #require(export.files["log.txt"]), as: UTF8.self)
        #expect(text.contains(operation.uuid.uuidString) && text.contains(error.userMessage) && text.contains(error.recoveryMessage))
    }

    @Test(arguments: [false, true])
    func omittedRunningCardCannotConfirmStopOrOfferForce(refusal: Bool) async throws {
        let fake = await configuredFake(), decision = Decision()
        let backend = HeldStopBackend(fake: fake, operation: operation, holdInventory: 2)
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit(); let work = try #require(quit.confirmStopAndQuit())
        var stops = backend.stopped.makeAsyncIterator(), inspections = backend.inspected.makeAsyncIterator()
        _ = await stops.next()
        backend.answer([.accepted(operation), refusal ? .failed(operation, .guestShutdownRefused(environment.id)) : .completed(operation)])
        _ = await inspections.next()
        backend.answerInventory([])
        await work.value
        #expect(quit.flow == .failed(.check(.unavailable(.invalidRuntimeReply(.malformed)))))
        #expect(decision.values.isEmpty && !quit.canForceStop)
    }

    @Test(arguments: [false, true])
    func changedOrMissingInstanceCannotReuseForceConsent(missing: Bool) async {
        let backend = await configuredFake(), decision = Decision()
        await backend.script("stopEnvironment", .fail(error: .guestShutdownRefused(environment.id)))
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: decision.record)
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(quit.canForceStop)
        await backend.setStatus(.init(environmentID: environment.id, vm: .running, readiness: .checking,
                                      runtimeInstanceID: missing ? nil : UUID()))
        await backend.script("stopEnvironment", .succeed(status: .init(environmentID: environment.id, vm: .stopped, readiness: .checking)))
        await quit.forceStopAndQuit()?.value
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { true } else { false } }
        #expect(stops == Array(repeating: .stopEnvironment(environment.id, .graceful(deadline: .seconds(60))), count: 2))
        #expect(decision.values == [true])
    }

    @Test func absentInstanceNeverOffersForceDespiteConfirmedRefusal() async {
        let backend = await configuredFake()
        await backend.setStatus(.init(environmentID: environment.id, vm: .running, readiness: .checking))
        await backend.script("stopEnvironment", .fail(error: .guestShutdownRefused(environment.id)))
        let quit = QuitCoordinator(model: AppModel(backend: backend), terminationDecision: { _ in })
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(!quit.canForceStop && quit.forceStopAndQuit() == nil)
    }

    @Test func everyFailureProvidesTypedRecovery() {
        let failures: [QuitCoordinator.Failure] = [.check(.checkingEnvironment), .check(.checked),
            .check(.metadataUnavailable(.repairRequired)), .check(.metadataUnavailable(.incompatible)),
            .check(.unavailable(.runtimeMissing)), .check(.interrupted(.connectionLost)),
            .ownership(environment.id, .ownershipUnproven), .unsettled(operation), .stillRunning,
            .stop(.guestShutdownRefused(environment.id)), .interrupted(.init(cause: .connectionLost))]
        for failure in failures {
            #expect(!failure.userMessage.isEmpty && !failure.recoveryMessage.isEmpty && !failure.recoveryActions.isEmpty)
        }
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
    private let pending = Mutex<(OperationID, AsyncThrowingStream<RuntimeEvent, any Error>.Continuation)?>(nil)
    private let inventory = Mutex<AsyncThrowingStream<RuntimeEvent, any Error>.Continuation?>(nil)
    private let counts = Mutex((inventories: 0, stops: [RuntimeRequest]()))
    private let holdInventory: Int?
    let inspected: AsyncStream<Void>
    private let inspectionSignal: AsyncStream<Void>.Continuation
    var stopRequests: [RuntimeRequest] { counts.withLock { $0.stops } }
    init(fake: FakeRuntimeBackend, operation: OperationID, holdInventory: Int? = nil) {
        self.fake = fake; self.operation = operation; self.holdInventory = holdInventory
        (inspected, inspectionSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (stopped, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    deinit { signal.finish(); inspectionSignal.finish() }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        if case .listEnvironments = request {
            let number = counts.withLock { $0.inventories += 1; return $0.inventories }
            if number == holdInventory {
                let (events, continuation) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
                inventory.withLock { $0 = continuation }; inspectionSignal.yield(()); return events
            }
        }
        guard case .stopEnvironment = request else { return fake.send(request) }
        let id = counts.withLock { state in defer { state.stops.append(request) }; return state.stops.isEmpty ? operation : OperationID() }
        let (events, continuation) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        pending.withLock { $0 = (id, continuation) }
        signal.yield(())
        return events
    }
    func finish() {
        guard let id = pending.withLock({ $0?.0 }) else { return }
        answer([.accepted(id), .progress(id, .init(kind: .stoppingVM, cancelable: true)), .completed(id)])
    }
    func answerInventory(_ records: [DevelopmentEnvironment]) {
        let reply = inventory.withLock { state in defer { state = nil }; return state }
        reply?.yield(.environments(.available(records))); reply?.finish()
    }
    func answer(_ events: [RuntimeEvent]) {
        let continuation = pending.withLock { state in defer { state = nil }; return state?.1 }
        for event in events { continuation?.yield(event) }
        continuation?.finish()
    }
}
