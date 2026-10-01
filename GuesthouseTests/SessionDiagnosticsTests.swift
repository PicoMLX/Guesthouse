import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor struct SessionDiagnosticsTests {
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
        #expect(model.sessionDiagnostics.records.count == 500 && model.sessionDiagnostics.discardedCount == 100)
        #expect(model.sessionDiagnostics.records.allSatisfy { $0.event.environmentID == environment.id })
        #expect(model.sessionDiagnostics.records.filter { $0.event.operationID == start.uuid }.count == 200)
        let text = model.sessionDiagnostics.text + String(decoding: try model.sessionDiagnostics.jsonData(), as: UTF8.self)
        #expect(!text.contains(marker))
        #expect(text.contains(GuesthouseError.runtimeMissing.userMessage) && text.contains(GuesthouseError.runtimeMissing.recoveryMessage))
        #expect(AppModel(backend: fake).sessionDiagnostics.records.isEmpty) // No cross-session history.
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
        #expect(model.sessionDiagnostics.records.isEmpty && tested.flow != .terminating)
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
