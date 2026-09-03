import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

/// A transport that answers from a script and can simulate a dropped connection.
final class FakeTransport: RuntimeTransport, @unchecked Sendable {
    enum Behavior { case reply(RuntimeEvent), fail, throwOnSend, acceptThenStream([RuntimeEvent]), acceptThenDrop, acceptLater }
    private var pendingReply: (@Sendable (Result<RuntimeEvent, any Error>) -> Void)?
    private(set) var lastAcceptedID: OperationID?

    /// For `.acceptLater`: delivers the `accepted` reply held back by the last send.
    func deliverPendingAccept() {
        let (reply, id) = lock.withLock { () -> ((@Sendable (Result<RuntimeEvent, any Error>) -> Void)?, OperationID) in
            let id = OperationID()
            lastAcceptedID = id
            defer { pendingReply = nil }
            return (pendingReply, id)
        }
        reply?(.success(.accepted(id)))
    }
    let lock = NSLock()
    var behavior: Behavior
    var incoming: (@Sendable (RuntimeEvent) -> Void)?
    var interrupted: (@Sendable () -> Void)?
    private var sentEnvelopes: [RuntimeRequestEnvelope] = []
    /// Snapshots taken under the lock, so a test polling while the client drains sees
    /// consistent state.
    var sent: [RuntimeRequestEnvelope] { lock.withLock { sentEnvelopes } }
    var sentCount: Int { lock.withLock { sentEnvelopes.count } }

    init(_ behavior: Behavior) { self.behavior = behavior }

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable () -> Void) {
        lock.withLock { self.incoming = incoming; self.interrupted = interrupted }
    }

    func send(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws {
        lock.withLock { sentEnvelopes.append(envelope) }
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
        case .acceptLater:
            if case .cancelOperation = envelope.request {
                reply(.success(.completed(OperationID())))
            } else {
                lock.withLock { pendingReply = reply }
            }
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
        for _ in 0..<200 where transport.sentCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        for _ in 0..<200 where transport.sentCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let sent = transport.sent
        guard sent.count == 2, case .cancelOperation = sent[1].request else { Issue.record("no cancelOperation sent: \(sent.map(\.request))"); return }
    }

    @Test func aConsumerGoneBeforeAcceptanceStillCancelsTheOperation() async throws {
        let transport = FakeTransport(.acceptLater)
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let consumer = Task { for try await _ in stream {} }
        for _ in 0..<200 where transport.sentCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        try await Task.sleep(for: .milliseconds(30))
        transport.deliverPendingAccept()
        for _ in 0..<200 where transport.sentCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let sent = transport.sent
        guard sent.count == 2, case .cancelOperation(let id) = sent[1].request else { Issue.record("no cancelOperation sent: \(sent.map(\.request))"); return }
        #expect(id == transport.lastAcceptedID)
    }

    @Test func aFloodNeverEvictsTheAcceptedEvent() async throws {
        let flood = (0..<3_000).map { _ in RuntimeEvent.progress(OperationID(), ProgressPhase(kind: .copying)) } + [.completed(OperationID())]
        let transport = FakeTransport(.acceptThenStream(flood))
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        try await Task.sleep(for: .milliseconds(200))
        let events = try await collect(stream)
        #expect(events.contains { if case .accepted = $0 { true } else { false } })
        #expect(events.last?.caseName == "completed")
        #expect(events.count <= RuntimeClient.consumerBufferLimit + 2)
    }

    @Test func aFailedSendDoesNotLeaveAnAbandonedMarker() async throws {
        let transport = FakeTransport(.throwOnSend)
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
        _ = try? await consumer.value
        try await Task.sleep(for: .milliseconds(50))
        let later = FakeTransport(.acceptThenStream([.completed(OperationID())]))
        let client2 = RuntimeClient(transport: later)
        let events = try await collect(client2.send(.startEnvironment(EnvironmentID(), StartOptions())))
        #expect(events.map(\.caseName) == ["accepted", "completed"])
        #expect(later.sent.count == 1, "no cancel was sent for a fresh operation")
    }

    @Test func aDiscardedClientIsReleased() async throws {
        weak var weakClient: RuntimeClient?
        do {
            let client = RuntimeClient(transport: FakeTransport(.reply(.runtimeVersion(RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1")))))
            _ = try await collect(client.send(.runtimeVersion))
            weakClient = client
        }
        for _ in 0..<100 where weakClient != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(weakClient == nil)
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
