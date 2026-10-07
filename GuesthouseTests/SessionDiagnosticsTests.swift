import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor struct SessionDiagnosticsTests {
    @Test(arguments: [false, true], [false, true])
    func runtimeConsumersRejectAppObservationClaims(stop: Bool, claimedRuntimeOrigin: Bool) async {
        let fake = FakeRuntimeBackend(), environment = DevelopmentEnvironment(name: "Dev Mac"), operation = OperationID()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: stop ? .running : .stopped,
            readiness: .checking, runtimeInstanceID: stop ? UUID() : nil))
        let event = DiagnosticEvent(operation: .inspectEnvironment, outcome: .observationFailed(.connectionLost),
            operationID: operation.uuid, environmentID: environment.id,
            origin: claimedRuntimeOrigin ? .runtimeOperation : .appObservation)
        let events: [RuntimeEvent] = [.accepted(operation), .diagnostic(event), .completed(operation)]
        let model = AppModel(backend: SessionBackend(fake: fake, start: events, stop: events))
        let failure = RuntimeSessionFailure(cause: .malformedResponse, operationID: operation, mayHaveMutated: true)
        if stop {
            let quit = QuitCoordinator(model: model) { _ in }
            _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
            #expect(quit.flow == .failed(.interrupted(failure)))
        } else {
            await model.checkEnvironments().value; await model.startEnvironment(environment.id)?.value
            #expect(model.startFailure == .interrupted(failure) && model.startNeedsInspection)
        }
        let expected = DiagnosticEvent(operation: stop ? .stopEnvironment : .startEnvironment,
            outcome: .operationFailed(.operationOutcomeUnknown(operation)), operationID: operation.uuid, environmentID: environment.id)
        #expect(model.sessionDiagnostics.records.map(\.event) == [expected])
        #expect(model.startDiagnostics.records.map(\.event) == (stop ? [] : [expected]))
    }

    @Test func sessionRetainsBoundedStartAndQuitEventsWithKnownEnvironmentAttribution() async throws {
        let environment = DevelopmentEnvironment(name: "Dev Mac"), start = OperationID(), stop = OperationID()
        let marker = "synthetic-private-token"
        let original = DiagnosticEvent(operation: .startEnvironment, outcome: .operationFailed(.runtimeMissing), operationID: start.uuid)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["stdout", "stderr", "underlyingError", "message", "token"] { object[key] = marker }
        let typed = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object))
        let stopped = DiagnosticEvent(operation: .stopEnvironment, outcome: .started, operationID: stop.uuid)
        let fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let backend = SessionBackend(fake: fake,
            start: [.accepted(start)] + Array(repeating: .diagnostic(typed), count: 300) + [.completed(start)],
            stop: [.accepted(stop)] + Array(repeating: .diagnostic(stopped), count: 300) + [.failed(stop, .canceled)])
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        await model.startEnvironment(environment.id)?.value
        #expect(model.startDiagnostics.records.count == 256 && model.sessionDiagnostics.records.count == 300)
        await fake.setStatus(.init(environmentID: environment.id, vm: .running, readiness: .checking, runtimeInstanceID: UUID()))
        let quit = QuitCoordinator(model: model) { _ in }
        _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
        #expect(model.sessionDiagnostics.records.count == 500 && model.sessionDiagnostics.discardedCount == 101)
        #expect(model.sessionDiagnostics.records.allSatisfy { $0.event.environmentID == environment.id })
        #expect(model.sessionDiagnostics.records.filter { $0.event.operationID == start.uuid }.count == 199)
        #expect(model.sessionDiagnostics.records.last?.event.outcome == .canceled)
        let text = model.sessionDiagnostics.text + String(decoding: try model.sessionDiagnostics.jsonData(), as: UTF8.self)
        #expect(!text.contains(marker))
        #expect(text.contains(GuesthouseError.runtimeMissing.userMessage) && text.contains(GuesthouseError.runtimeMissing.recoveryMessage))
        #expect(AppModel(backend: fake).sessionDiagnostics.records.isEmpty) // No cross-session history.
    }

    @Test(arguments: [false, true], [false, true])
    func nestedOutcomeIdentitiesMustMatchTargetAndOperation(stop: Bool, foreign: Bool) async {
        let environment = DevelopmentEnvironment(name: "Dev Mac"), operation = OperationID(), fake = FakeRuntimeBackend()
        let target = foreign ? EnvironmentID() : environment.id
        let errors: [GuesthouseError] = [.guestNotReachable(target), .hostKeyChanged(target), .guestShutdownRefused(target),
            .operationOutcomeUnknown(foreign ? OperationID() : operation)]
        for error in errors {
            await fake.setEnvironmentInventory(.available([environment]))
            await fake.setStatus(.init(environmentID: environment.id, vm: stop ? .running : .stopped, readiness: .checking, runtimeInstanceID: stop ? UUID() : nil))
            let diagnostic = DiagnosticEvent(operation: stop ? .stopEnvironment : .startEnvironment,
                outcome: .operationFailed(error), operationID: operation.uuid)
            let events: [RuntimeEvent] = [.accepted(operation), .diagnostic(diagnostic), .failed(operation, .canceled)]
            let model = AppModel(backend: SessionBackend(fake: fake, start: events, stop: events))
            if stop {
                let quit = QuitCoordinator(model: model) { _ in }
                _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
                if foreign { #expect(quit.flow == .failed(.interrupted(.init(cause: .malformedResponse, operationID: operation, mayHaveMutated: true)))) }
            } else {
                await model.checkEnvironments().value; await model.startEnvironment(environment.id)?.value
                if foreign { #expect(model.startFailure == .interrupted(.init(cause: .malformedResponse, operationID: operation, mayHaveMutated: true))) }
            }
            #expect(model.sessionDiagnostics.records.count == (foreign ? 1 : 2))
            #expect(model.startDiagnostics.records.count == (stop ? 0 : foreign ? 1 : 2))
            if foreign {
                #expect(model.sessionDiagnostics.records.first?.event == DiagnosticEvent(operation: stop ? .stopEnvironment : .startEnvironment,
                    outcome: .operationFailed(.operationOutcomeUnknown(operation)), operationID: operation.uuid, environmentID: environment.id))
            }
        }
    }

    @Test(arguments: [false, true]) func quitRejectsForeignEnvironmentOrOperation(foreignEnvironment: Bool) async {
        let environment = DevelopmentEnvironment(name: "Dev Mac"), operation = OperationID(), fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: .running, readiness: .checking, runtimeInstanceID: UUID()))
        let diagnostic = DiagnosticEvent(operation: .stopEnvironment, outcome: .started,
            operationID: foreignEnvironment ? operation.uuid : UUID(), environmentID: foreignEnvironment ? EnvironmentID() : environment.id)
        let backend = SessionBackend(fake: fake, start: [], stop: [.accepted(operation), .diagnostic(diagnostic), .completed(operation)])
        let model = AppModel(backend: backend)
        // Use the model whose session receives the operation, independent of any window.
        let tested = QuitCoordinator(model: model) { _ in }
        _ = tested.requestQuit(); await tested.confirmStopAndQuit()?.value
        #expect(model.sessionDiagnostics.records.map(\.event) == [DiagnosticEvent(operation: .stopEnvironment,
            outcome: .operationFailed(.operationOutcomeUnknown(operation)), operationID: operation.uuid, environmentID: environment.id)])
        #expect(tested.flow != .terminating)
    }

    @Test(arguments: [false, true], [false, true])
    func terminalErrorsValidateNestedIdentitiesBeforeRetention(stop: Bool, foreign: Bool) async {
        let environment = DevelopmentEnvironment(name: "Dev Mac"), operation = OperationID(), fake = FakeRuntimeBackend()
        let target = foreign ? EnvironmentID() : environment.id
        var errors: [GuesthouseError] = [.guestNotReachable(target), .hostKeyChanged(target),
            .operationOutcomeUnknown(foreign ? OperationID() : operation)]
        if stop { errors.append(.guestShutdownRefused(target)) }
        for error in errors {
            await fake.setEnvironmentInventory(.available([environment]))
            await fake.setStatus(.init(environmentID: environment.id, vm: stop ? .running : .stopped,
                readiness: .checking, runtimeInstanceID: stop ? UUID() : nil))
            let events: [RuntimeEvent] = [.accepted(operation), .failed(operation, error)]
            let model = AppModel(backend: SessionBackend(fake: fake, start: events, stop: events))
            let malformed = RuntimeSessionFailure(cause: .malformedResponse, operationID: operation, mayHaveMutated: true)
            if stop {
                let quit = QuitCoordinator(model: model) { _ in }
                _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
                if foreign { #expect(quit.flow == .failed(.interrupted(malformed))) }
            } else {
                await model.checkEnvironments().value; await model.startEnvironment(environment.id)?.value
                if foreign { #expect(model.startFailure == .interrupted(malformed)) }
            }
            let expected = DiagnosticEvent(operation: stop ? .stopEnvironment : .startEnvironment,
                outcome: .init(error: error), operationID: operation.uuid, environmentID: environment.id)
            let unknown = DiagnosticEvent(operation: stop ? .stopEnvironment : .startEnvironment,
                outcome: .operationFailed(.operationOutcomeUnknown(operation)), operationID: operation.uuid, environmentID: environment.id)
            #expect(model.sessionDiagnostics.records.map(\.event) == [foreign ? unknown : expected])
        }
    }

    @Test(arguments: [false, true], [false, true])
    func terminalFailureUsesItsActualIDAndConfirmedCancellationOutcome(stop: Bool, accepted: Bool) async {
        let environment = DevelopmentEnvironment(name: "Dev Mac"), operation = OperationID(), fake = FakeRuntimeBackend()
        await fake.setEnvironmentInventory(.available([environment]))
        await fake.setStatus(.init(environmentID: environment.id, vm: stop ? .running : .stopped,
            readiness: .checking, runtimeInstanceID: stop ? UUID() : nil))
        let error: GuesthouseError = accepted ? .canceled : .invalidRequest(.tooManyInFlight)
        let events: [RuntimeEvent] = (accepted ? [.accepted(operation)] : []) + [.failed(operation, error)]
        let model = AppModel(backend: SessionBackend(fake: fake, start: events, stop: events))
        if stop {
            let quit = QuitCoordinator(model: model) { _ in }
            _ = quit.requestQuit(); await quit.confirmStopAndQuit()?.value
            #expect(!quit.canForceStop && quit.flow == .failed(.stop(error)))
        } else {
            await model.checkEnvironments().value; await model.startEnvironment(environment.id)?.value
            #expect(model.startFailure == .runtime(error) && model.startMayHaveMutated == accepted)
        }
        let expected = DiagnosticEvent(operation: stop ? .stopEnvironment : .startEnvironment,
            outcome: accepted ? .canceled : .operationFailed(error), operationID: operation.uuid, environmentID: environment.id)
        #expect(model.sessionDiagnostics.records.map(\.event) == [expected])
        #expect(model.startDiagnostics.records.map(\.event) == (stop || !accepted ? [] : [expected]))
    }
}

private nonisolated struct SessionBackend: RuntimeBackend {
    let fake: FakeRuntimeBackend
    let start: [RuntimeEvent], stop: [RuntimeEvent]
    var allowsEnvironmentStart: Bool { true }
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { fake.connectionInterruptions }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        let events: [RuntimeEvent]
        switch request {
        case .startEnvironment: events = start
        case .stopEnvironment: events = stop
        default: return fake.send(request)
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
