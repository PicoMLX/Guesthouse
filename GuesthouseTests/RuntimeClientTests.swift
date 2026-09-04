import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

/// A transport that answers from a script and can simulate a dropped connection.
final class FakeTransport: RuntimeTransport, @unchecked Sendable {
    enum Behavior { case reply(RuntimeEvent), fail, throwOnSend, acceptThenStream([RuntimeEvent]), acceptThenDrop, acceptLater }
    private var pendingReply: (@Sendable (Result<RuntimeEvent, any Error>) -> Void)?
    private(set) var lastAcceptedID: OperationID?

    /// The id the held-back `accepted` reply will carry, known before acceptance so a test can
    /// push events that arrive before it.
    let preparedID = OperationID()

    /// For `.acceptLater`: delivers the `accepted` reply held back by the last send.
    func deliverPendingAccept() {
        let reply = lock.withLock { () -> (@Sendable (Result<RuntimeEvent, any Error>) -> Void)? in
            lastAcceptedID = preparedID
            defer { pendingReply = nil }
            return pendingReply
        }
        reply?(.success(.accepted(preparedID)))
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

private struct MissedDeadline: Error {}

/// Runs `work` with a deadline, so a client that stops delivering fails the test instead of
/// hanging the run.
private func withDeadline<T: Sendable>(_ duration: Duration = .seconds(10), _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try? await Task.sleep(for: duration)
            return nil
        }
        let finished = try await group.next()
        group.cancelAll()
        guard let value = finished ?? nil else { throw MissedDeadline() }
        return value
    }
}

private func collected(from stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
    var events: [RuntimeEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

@Suite struct RuntimeClientTests {
    func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func theAcceptedEventArrivesBeforeAnyTraffic() async throws {
        let flood = (0..<(RuntimeClient.consumerBufferLimit * 2)).map { index in RuntimeEvent.log(OperationID(), Redactor().redact(lines: ["line \(index)"])[0]) } + [.completed(OperationID())]
        let transport = FakeTransport(.acceptThenStream(flood))
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        try await Task.sleep(for: .milliseconds(200))
        let events = try await collect(stream)
        #expect(events.first?.caseName == "accepted", "the operation id is learned before any traffic")
        #expect(events.last?.caseName == "completed")
        #expect(events.count <= RuntimeClient.consumerBufferLimit + 2, "the excess was dropped, not buffered")
    }

    @Test func lateEventsForAFinishedOperationAreDropped() async throws {
        let transport = FakeTransport(.acceptThenStream([.completed(OperationID())]))
        let client = RuntimeClient(transport: transport)
        let events = try await collect(client.send(.startEnvironment(EnvironmentID(), StartOptions())))
        guard case .accepted(let id)? = events.first else { Issue.record("no accepted event"); return }
        let incoming = transport.lock.withLock { transport.incoming }
        for index in 0..<10 { incoming?(.log(id, Redactor().redact(lines: ["late \(index)"])[0])) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await client.pendingEventCount(for: id) == 0, "a finished operation buffers nothing")
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

    @Test func aTerminalEventSurvivesAFloodThatArrivesBeforeAcceptance() async throws {
        let transport = FakeTransport(.acceptLater)
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        for _ in 0..<200 where transport.sentCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let incoming = transport.lock.withLock { transport.incoming }
        let id = transport.preparedID
        // Every push is enqueued on the client's ordered inbox before the acceptance below,
        // so all of this traffic is handled while the operation is still unaccepted.
        for _ in 0..<(RuntimeClient.pendingEventLimit * 2) { incoming?(.progress(id, ProgressPhase(kind: .copying))) }
        incoming?(.completed(id))
        transport.deliverPendingAccept()
        let events = try await withDeadline { try await collected(from: stream) }
        #expect(events.last?.caseName == "completed", "the terminal event outlives the traffic that preceded it")
        #expect(events.count <= RuntimeClient.pendingEventLimit + 1, "the buffer stayed bounded")
    }

    @Test func aConsumerThatKeepsUpNeverStopsReceivingTraffic() async throws {
        let transport = FakeTransport(.acceptThenStream([]))
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let total = RuntimeClient.consumerBufferLimit * 2
        let received = try await withDeadline { () -> Int in
            var iterator = stream.makeAsyncIterator()
            guard case .accepted(let id)? = try await iterator.next() else { return 0 }
            let incoming = transport.lock.withLock { transport.incoming }
            var received = 0
            for _ in 0..<total {
                incoming?(.progress(id, ProgressPhase(kind: .copying)))
                if case .progress? = try await iterator.next() { received += 1 }
            }
            return received
        }
        #expect(received == total, "a consumer reading in real time is never cut off")
    }

    @Test func unscopedLogsAreBoundedLikeOtherTraffic() async throws {
        let transport = FakeTransport(.acceptThenStream([]))
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        var iterator = stream.makeAsyncIterator()
        guard case .accepted(let id)? = try await iterator.next() else {
            Issue.record("no accepted event")
            return
        }
        let incoming = transport.lock.withLock { transport.incoming }
        let line = Redactor().redact(lines: ["unscoped guest output"])[0]
        for _ in 0..<(RuntimeClient.consumerBufferLimit * 4) { incoming?(.log(nil, line)) }
        incoming?(.completed(id))
        // Nothing is read until the flood has been routed and the stream finished, so this
        // measures what the client was willing to hold for a consumer that is not keeping up,
        // and the drain below cannot wait on anything.
        for _ in 0..<400 where await client.isRetired(id) == false { try await Task.sleep(for: .milliseconds(5)) }
        guard await client.isRetired(id) else {
            Issue.record("the flood was never routed")
            return
        }
        var delivered: [RuntimeEvent] = []
        while let event = try await iterator.next() { delivered.append(event) }
        #expect(delivered.count <= RuntimeClient.consumerBufferLimit, "unscoped output cannot accumulate without limit")
        #expect(delivered.last?.caseName == "completed", "unscoped output never crowds out the terminal event")
    }

    @Test func aQueryThatFinishesNormallyReleasesItsKey() async throws {
        let info = RuntimeVersionInfo(serviceVersion: "1.0", serviceBuild: "7")
        let transport = FakeTransport(.reply(.runtimeVersion(info)))
        let client = RuntimeClient(transport: transport)
        for _ in 0..<10 { _ = try await collect(client.send(.runtimeVersion)) }
        for _ in 0..<200 where await client.settledKeyCount() > 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await client.settledKeyCount() == 0, "finished queries do not accumulate for the life of the client")
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

/// The transport's session rules, exercised without a live XPC connection.
@Suite struct SessionRegistryTests {
    @Test func aReplyFromARetiredSessionBecomesAnInterruption() {
        let registry = SessionRegistry<NSObject>()
        let (_, generation) = registry.session { _ in NSObject() }
        guard case .success = registry.gate(.success(.accepted(OperationID())), from: generation) else {
            Issue.record("the live session's reply was not forwarded")
            return
        }
        _ = registry.retire(generation)
        guard case .failure(let error) = registry.gate(.success(.accepted(OperationID())), from: generation) else {
            Issue.record("an accepted reply from a retired session was forwarded")
            return
        }
        #expect(error is RuntimeConnectionInterrupted)
    }

    @Test func aSessionIsRetiredOnce() {
        let registry = SessionRegistry<NSObject>()
        let (_, generation) = registry.session { _ in NSObject() }
        registry.setHandlers(incoming: { _ in }, interrupted: {})
        #expect(registry.retire(generation).interrupted != nil)
        #expect(registry.retire(generation).interrupted == nil, "a second failure of the same session reports nothing")
    }

    @Test func aRetirementCannotOvertakeAnEventBeingDelivered() {
        let registry = SessionRegistry<NSObject>()
        let (_, generation) = registry.session { _ in NSObject() }
        let retired = DispatchSemaphore(value: 0)
        registry.setHandlers(
            incoming: { _ in
                DispatchQueue.global().async {
                    _ = registry.retire(generation)
                    retired.signal()
                }
                // A retirement racing this delivery must wait for it: the generation check and
                // the handoff to the client are one step, so a stale event can never be queued
                // behind the operations of a replacement session.
                #expect(retired.wait(timeout: .now() + .milliseconds(300)) == .timedOut)
            },
            interrupted: {}
        )
        registry.deliverIncoming(.progress(OperationID(), ProgressPhase(kind: .copying)), from: generation)
        #expect(retired.wait(timeout: .now() + .seconds(5)) == .success, "the retirement completed once delivery was done")
    }

    @Test func aRetiredSessionDeliversNothing() {
        let registry = SessionRegistry<NSObject>()
        let (_, generation) = registry.session { _ in NSObject() }
        let delivered = DispatchSemaphore(value: 0)
        registry.setHandlers(incoming: { _ in delivered.signal() }, interrupted: {})
        _ = registry.retire(generation)
        registry.deliverIncoming(.progress(OperationID(), ProgressPhase(kind: .copying)), from: generation)
        #expect(delivered.wait(timeout: .now()) == .timedOut)
    }
}
