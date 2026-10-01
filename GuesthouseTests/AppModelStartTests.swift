import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import Guesthouse

@MainActor @Suite(.timeLimit(.minutes(1))) struct AppModelStartTests {
    let environment = DevelopmentEnvironment(name: "Dev Mac")
    let operation = OperationID()
    func configured() async -> FakeRuntimeBackend {
        let fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        return fake
    }
    @Test func allStartFailuresHaveFixedGuidanceAndTypedRecovery() {
        let failures: [StartOperation.Failure] = [.quitPending, .stateChanged, .notRunning, .check(.checkingEnvironment),
            .runtime(.runtimeIncompatible), .interrupted(.init(cause: .connectionLost, operationID: operation, mayHaveMutated: true))]
        for failure in failures { #expect(!failure.message.isEmpty && !failure.recoveryActions.isEmpty) }
    }
    @Test func restrictedBackendNeverEnablesOrSendsStart() async {
        let fake = await configured(), backend = QueryOnlyBackend(fake: fake)
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        #expect(model.statuses[environment.id]?.vm == .stopped)
        #expect(!backend.allowsEnvironmentStart && !model.canStart(environment.id))
        #expect(model.startEnvironment(environment.id) == nil)
        #expect(await fake.receivedRequests == [.listEnvironments, .environmentStatus(environment.id)])
        let card = EnvironmentCardState(environment: environment, status: model.statuses[environment.id], checked: true, busy: false)
        #expect(card.startBlockedReason.contains("verified VM provider"))
    }
    @Test func startInspectsSendsOnceAndInspectsAgain() async throws {
        let fake = await configured(), model = AppModel(backend: fake)
        await model.checkEnvironments().value
        await fake.script("startEnvironment", .succeed(status: .init(environmentID: environment.id, vm: .running, readiness: .ready)))
        let task = try #require(model.startEnvironment(environment.id))
        #expect(model.startEnvironment(environment.id) == nil)
        await task.value
        #expect(!model.isStarting && model.startFailure == nil && model.statuses[environment.id]?.vm == .running)
        #expect(await fake.receivedRequests == [.listEnvironments, .environmentStatus(environment.id),
            .listEnvironments, .environmentStatus(environment.id), .startEnvironment(environment.id, .init()),
            .listEnvironments, .environmentStatus(environment.id)])
    }
    @Test func interruptedStartRetainsAcceptedIdentityAndRequiresExplicitInspection() async throws {
        let fake = await configured(), model = AppModel(backend: fake)
        await model.checkEnvironments().value
        await fake.useOperationID(operation, forNext: "startEnvironment")
        await fake.script("startEnvironment", .disconnect())
        await model.startEnvironment(environment.id)?.value
        #expect(model.startFailure == .interrupted(.init(cause: .connectionLost, operationID: operation, mayHaveMutated: true)))
        #expect(!model.canStart(environment.id))
        #expect(await fake.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }.count == 1)
        await model.checkEnvironments().value
        #expect(model.startFailure != nil) // The fake still reports the interrupted operation in flight.
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        await model.checkEnvironments().value
        #expect(model.startFailure == nil)
    }
    @Test func completedStartWithoutRunningStatusKeepsActionableFailure() async {
        let fake = await configured(), model = AppModel(backend: fake)
        await model.checkEnvironments().value
        #expect(model.canStart(environment.id)) // Stopped/checking is valid before guest boot.
        await model.startEnvironment(environment.id)?.value
        #expect(model.startFailure == .notRunning && !model.canStart(environment.id))
    }
    @Test func anotherEnvironmentCannotEraseAnUnresolvedFailure() async {
        let fake = await configured(), second = DevelopmentEnvironment(name: "Second Mac")
        await fake.setEnvironmentInventory(.available([environment, second]))
        await fake.setStatus(.init(environmentID: second.id, vm: .stopped, readiness: .checking))
        let model = AppModel(backend: fake); await model.checkEnvironments().value
        await fake.script("startEnvironment", .disconnect())
        await model.startEnvironment(environment.id)?.value
        let failure = model.startFailure
        #expect(failure != nil && !model.canStart(second.id) && model.startEnvironment(second.id) == nil)
        #expect(model.startFailure == failure && model.startingEnvironment == environment.id)
        await fake.setEnvironmentInventory(.available([second]))
        await model.checkEnvironments().value
        #expect(model.startFailure == failure && !model.canStart(second.id))
        await fake.setEnvironmentInventory(.available([environment, second]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        await model.checkEnvironments().value
        #expect(model.startFailure == nil && model.canStart(second.id))
    }
    @Test func quitBeforeAdmissionPreventsStart() async {
        let fake = await configured(), model = AppModel(backend: fake)
        await model.checkEnvironments().value
        let start = model.startEnvironment(environment.id)
        let quit = QuitCoordinator(model: model, terminationDecision: { _ in })
        _ = quit.requestQuit()
        await start?.value
        #expect(await fake.receivedRequests.allSatisfy { if case .startEnvironment = $0 { false } else { true } })
        #expect(!model.isStarting && model.startFailure == .quitPending)
    }
    @Test func quitWaitsForAcceptedStartBeforeStoppingAndChecksDoNotInterfere() async throws {
        let fake = await configured(), backend = HeldStartBackend(fake: fake), decisions = StartDecisions()
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        let start = try #require(model.startEnvironment(environment.id))
        var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        let joined = model.checkEnvironments()
        let quit = QuitCoordinator(model: model, terminationDecision: decisions.record)
        _ = quit.requestQuit(); let quitting = try #require(quit.confirmStopAndQuit())
        #expect(decisions.values.isEmpty && model.startEnvironment(environment.id) == nil)
        await fake.setStatus(.init(environmentID: environment.id, vm: .running, readiness: .ready))
        await fake.script("stopEnvironment", .succeed(status: .init(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        backend.answer([.accepted(operation), .completed(operation)])
        await start.value; await joined.value; await quitting.value
        #expect(decisions.values == [true] && quit.flow == .terminating)
        let requests = await fake.receivedRequests
        #expect(requests.filter { if case .stopEnvironment = $0 { true } else { false } }.count == 1)
    }
    @Test(arguments: [false, true])
    func malformedTerminalOrForeignStatusKeepsUnknownIdentity(foreign: Bool) async throws {
        let fake = await configured(), backend = HeldStartBackend(fake: fake), model = AppModel(backend: backend)
        await model.checkEnvironments().value
        let start = try #require(model.startEnvironment(environment.id))
        var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        backend.answer([.accepted(operation), foreign
            ? .status(.init(environmentID: EnvironmentID(), vm: .running, readiness: .ready))
            : .completed(OperationID())])
        await start.value
        #expect(model.startFailure == .interrupted(.init(cause: .malformedResponse, operationID: operation, mayHaveMutated: true)))
        #expect(!model.canStart(environment.id))
    }
}

@MainActor private final class StartDecisions {
    var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}
private nonisolated final class HeldStartBackend: RuntimeBackend {
    let fake: FakeRuntimeBackend
    var allowsEnvironmentStart: Bool { fake.allowsEnvironmentStart }
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { fake.connectionInterruptions }
    let sent: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let pending = Mutex<AsyncThrowingStream<RuntimeEvent, any Error>.Continuation?>(nil)
    init(fake: FakeRuntimeBackend) { self.fake = fake; (sent, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    deinit { signal.finish() }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        guard case .startEnvironment = request else { return fake.send(request) }
        let (events, continuation) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        pending.withLock { $0 = continuation }; signal.yield(()); return events
    }
    func answer(_ events: [RuntimeEvent]) {
        let continuation = pending.withLock { state in defer { state = nil }; return state }
        for event in events { continuation?.yield(event) }; continuation?.finish()
    }
}

private nonisolated struct QueryOnlyBackend: RuntimeBackend {
    let fake: FakeRuntimeBackend
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { fake.connectionInterruptions }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> { fake.send(request) }
}
