import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

/// A transport that answers from a script and can simulate a dropped connection.
final class FakeTransport: RuntimeTransport, @unchecked Sendable {
    enum Behavior { case reply(RuntimeEvent), fail, throwOnSend, acceptThenStream([RuntimeEvent]), acceptThenDrop }
    let lock = NSLock()
    var behavior: Behavior
    var incoming: (@Sendable (RuntimeEvent) -> Void)?
    var interrupted: (@Sendable () -> Void)?
    var sent: [RuntimeRequestEnvelope] = []

    init(_ behavior: Behavior) { self.behavior = behavior }

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable () -> Void) {
        lock.withLock { self.incoming = incoming; self.interrupted = interrupted }
    }

    func send(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws {
        lock.withLock { sent.append(envelope) }
        switch behavior {
        case .reply(let event): reply(.success(event))
        case .fail: reply(.failure(CocoaError(.xpcConnectionInterrupted)))
        case .throwOnSend: throw CocoaError(.xpcConnectionInvalid)
        case .acceptThenStream(let events):
            let id = OperationID()
            reply(.success(.accepted(id)))
            let incoming = lock.withLock { self.incoming }
            for event in events {
                switch event {
                case .progress(_, let phase): incoming?(.progress(id, phase))
                case .completed: incoming?(.completed(id))
                case .failed(_, let error): incoming?(.failed(id, error))
                default: incoming?(event)
                }
            }
        case .acceptThenDrop:
            reply(.success(.accepted(OperationID())))
            lock.withLock { self.interrupted }?()
        }
    }
}

@Suite struct RuntimeClientTests {
    func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func runtimeVersionReplyBecomesOneEventAndFinishes() async throws {
        let info = RuntimeVersionInfo(serviceVersion: "1.0", serviceBuild: "7")
        let transport = FakeTransport(.reply(.runtimeVersion(info)))
        let client = RuntimeClient(transport: transport)
        let events = try await collect(client.send(.runtimeVersion))
        #expect(events == [.runtimeVersion(info)])
        #expect(transport.sent.map(\.request) == [.runtimeVersion])
        #expect(transport.sent.first?.protocolVersion == .current)
    }

    @Test func replyFailureIsAnInterruption() async {
        let client = RuntimeClient(transport: FakeTransport(.fail))
        await #expect(throws: RuntimeConnectionInterrupted.self) {
            for try await _ in client.send(.runtimeVersion) {}
        }
    }

    @Test func sendFailureIsAnInterruption() async {
        let client = RuntimeClient(transport: FakeTransport(.throwOnSend))
        await #expect(throws: RuntimeConnectionInterrupted.self) {
            for try await _ in client.send(.runtimeVersion) {}
        }
    }

    @Test func acceptedOperationsStreamUntilCompleted() async throws {
        let phase = ProgressPhase(kind: .startingVM)
        let transport = FakeTransport(.acceptThenStream([.progress(OperationID(), phase), .completed(OperationID())]))
        let client = RuntimeClient(transport: transport)
        let events = try await collect(client.send(.startEnvironment(EnvironmentID(), StartOptions())))
        #expect(events.map(\.caseName) == ["accepted", "progress", "completed"])
    }

    @Test func requestsReachTheTransportInSendOrder() async throws {
        let transport = FakeTransport(.reply(.completed(OperationID())))
        let client = RuntimeClient(transport: transport)
        let requests: [RuntimeRequest] = (0..<25).map { $0.isMultiple(of: 2) ? .startEnvironment(EnvironmentID(), StartOptions()) : .stopEnvironment(EnvironmentID(), .force) }
        var streams: [AsyncThrowingStream<RuntimeEvent, any Error>] = []
        for request in requests { streams.append(client.send(request)) }
        for stream in streams { _ = try await collect(stream) }
        #expect(transport.sent.map(\.request) == requests)
    }

    @Test func abandonedConsumerCancelsTheOperation() async throws {
        let transport = FakeTransport(.acceptThenStream([]))
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let consumer = Task { for try await _ in stream {} }
        for _ in 0..<200 where transport.sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        for _ in 0..<200 where transport.sent.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        guard transport.sent.count == 2, case .cancelOperation = transport.sent[1].request else { Issue.record("no cancelOperation sent: \(transport.sent.map(\.request))"); return }
    }

    @Test func droppedConnectionFailsInFlightOperationsWithTheirID() async {
        let client = RuntimeClient(transport: FakeTransport(.acceptThenDrop))
        var seen: [String] = []
        var interruption: RuntimeConnectionInterrupted?
        do {
            for try await event in client.send(.startEnvironment(EnvironmentID(), StartOptions())) { seen.append(event.caseName) }
        } catch let error as RuntimeConnectionInterrupted {
            interruption = error
        } catch {}
        #expect(seen == ["accepted"])
        #expect(interruption?.operationID != nil)
    }
}
