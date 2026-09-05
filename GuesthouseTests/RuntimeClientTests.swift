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
    /// Run at the start of the next send, while the client is inside the transport and so
    /// cannot drain its inbox. Lets a test enqueue callbacks in a known order, and observe
    /// what an undrained inbox holds. Consumed by the send that runs it.
    var beforeSend: (@Sendable () -> Void)?
    private var sentEnvelopes: [RuntimeRequestEnvelope] = []
    /// Snapshots taken under the lock, so a test polling while the client drains sees
    /// consistent state.
    var sent: [RuntimeRequestEnvelope] { lock.withLock { sentEnvelopes } }
    var sentCount: Int { lock.withLock { sentEnvelopes.count } }

    init(_ behavior: Behavior) { self.behavior = behavior }

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable () -> Void) {
        lock.withLock { self.incoming = incoming; self.interrupted = interrupted }
    }

    /// For `.acceptLater`: fails the reply held back by the last send.
    func failPendingReply() {
        let reply = lock.withLock { () -> (@Sendable (Result<RuntimeEvent, any Error>) -> Void)? in
            defer { pendingReply = nil }
            return pendingReply
        }
        reply?(.failure(CocoaError(.xpcConnectionInterrupted)))
    }

    func send(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws {
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { beforeSend = nil }
            return beforeSend
        }
        hook?()
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

/// A value handed to a callback, readable from the thread that waits for it.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// How many times a callback ran.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// The order in which things happened across threads.
final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func append(_ entry: String) { lock.withLock { recorded.append(entry) } }
    var entries: [String] { lock.withLock { recorded } }
}

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

    @Test func aTerminalEventSurvivesAConsumerThatNeverReads() async throws {
        let transport = FakeTransport(.acceptThenStream([]))
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        var iterator = stream.makeAsyncIterator()
        guard case .accepted(let id)? = try await iterator.next() else {
            Issue.record("no accepted event")
            return
        }
        let incoming = transport.lock.withLock { transport.incoming }
        // Far more traffic than the control reserve can absorb. The probe that measures how
        // much room a consumer has left occupies a slot itself, so without a floor these
        // probes fill the buffer to the brim and the terminal event is refused. Nothing is
        // read in between, so this is a consumer that has stopped entirely.
        for _ in 0..<12 {
            for _ in 0..<1_000 { incoming?(.progress(id, ProgressPhase(kind: .copying))) }
            try await Task.sleep(for: .milliseconds(20))
        }
        incoming?(.completed(id))
        for _ in 0..<400 where await client.isRetired(id) == false { try await Task.sleep(for: .milliseconds(5)) }
        var delivered: [RuntimeEvent] = []
        while let event = try await iterator.next() { delivered.append(event) }
        #expect(delivered.last?.caseName == "completed", "the terminal event outlives a consumer that stopped reading")
    }

    @Test func statusSnapshotsNeverCrowdOutTheTerminalEvent() async throws {
        let transport = FakeTransport(.acceptThenStream([]))
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        var iterator = stream.makeAsyncIterator()
        guard case .accepted(let id)? = try await iterator.next() else {
            Issue.record("no accepted event")
            return
        }
        let incoming = transport.lock.withLock { transport.incoming }
        let status = EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped, readiness: .ready)
        for _ in 0..<(RuntimeClient.consumerBufferLimit * 4) { incoming?(.status(status)) }
        incoming?(.completed(id))
        for _ in 0..<400 where await client.isRetired(id) == false { try await Task.sleep(for: .milliseconds(5)) }
        var delivered: [RuntimeEvent] = []
        while let event = try await iterator.next() { delivered.append(event) }
        #expect(delivered.count <= RuntimeClient.consumerBufferLimit, "repeated snapshots cannot accumulate without limit")
        #expect(delivered.last?.caseName == "completed", "a snapshot never takes the slot the terminal event needs")
    }

    /// A snapshot that names the operation it belongs to is that operation's event; the
    /// stream of another request must not be told about it.
    @Test func aStatusReachesOnlyTheOperationItNames() async throws {
        let transport = FakeTransport(.acceptThenStream([]))
        let client = RuntimeClient(transport: transport)
        let first = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        var firstEvents = first.makeAsyncIterator()
        guard case .accepted(let firstID)? = try await firstEvents.next() else {
            Issue.record("no accepted event for the first operation")
            return
        }
        let second = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        var secondEvents = second.makeAsyncIterator()
        guard case .accepted(let secondID)? = try await secondEvents.next() else {
            Issue.record("no accepted event for the second operation")
            return
        }
        let incoming = transport.lock.withLock { transport.incoming }
        incoming?(.status(EnvironmentStatus(environmentID: EnvironmentID(), vm: .running, readiness: .ready, inFlightOperation: secondID)))
        // A snapshot that names no operation describes the environment, so it still reaches
        // every stream.
        incoming?(.status(EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped, readiness: .ready)))
        incoming?(.completed(firstID))
        incoming?(.completed(secondID))
        var delivered: [String] = []
        while let event = try await firstEvents.next() { delivered.append(event.caseName) }
        #expect(delivered == ["status", "completed"], "only the unscoped snapshot reached the other operation")
        var owned: [String] = []
        while let event = try await secondEvents.next() { owned.append(event.caseName) }
        #expect(owned == ["status", "status", "completed"])
    }

    /// A snapshot naming an operation whose `accepted` reply has not arrived yet waits in the
    /// same bounded buffer its progress does, instead of being dropped.
    @Test func aStatusThatArrivesBeforeAcceptanceIsNotLost() async throws {
        let transport = FakeTransport(.acceptLater)
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        for _ in 0..<200 where transport.sentCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let incoming = transport.lock.withLock { transport.incoming }
        let id = transport.preparedID
        incoming?(.status(EnvironmentStatus(environmentID: EnvironmentID(), vm: .running, readiness: .ready, inFlightOperation: id)))
        incoming?(.completed(id))
        transport.deliverPendingAccept()
        let events = try await withDeadline { try await collected(from: stream) }
        #expect(events.map(\.caseName) == ["accepted", "status", "completed"])
    }

    /// The per-operation cap says nothing about how many operations there are, and a terminal
    /// event is never refused at ingress, so a service streaming ids nothing asked for would
    /// otherwise grow the buffer dictionary itself.
    @Test func preAcceptanceBuffersAreBoundedAcrossOperations() async throws {
        let transport = FakeTransport(.acceptLater)
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        for _ in 0..<200 where transport.sentCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let incoming = transport.lock.withLock { transport.incoming }
        let id = transport.preparedID
        incoming?(.progress(id, ProgressPhase(kind: .copying)))
        for _ in 0..<(RuntimeClient.pendingOperationLimit * 4) { incoming?(.completed(OperationID())) }
        incoming?(.completed(id))
        transport.deliverPendingAccept()
        let events = try await withDeadline { try await collected(from: stream) }
        #expect(events.last?.caseName == "completed", "the operation the app asked for kept its buffer")
        let held = await client.pendingOperationCount()
        #expect(held <= RuntimeClient.pendingOperationLimit, "ids nothing asked for cannot grow the buffer without limit")
    }

    @Test func trafficIsBoundedBeforeItReachesTheInbox() async throws {
        let transport = FakeTransport(.acceptLater)
        let client = RuntimeClient(transport: transport)
        let measured = Box<Int>()
        transport.beforeSend = { [weak client] in
            guard let client else { return }
            let incoming = transport.lock.withLock { transport.incoming }
            let id = OperationID()
            // The client is inside this send, so none of this can have been drained yet: what
            // the inbox holds afterwards is what it was willing to accept.
            for _ in 0..<(RuntimeClient.inboxTrafficLimit + 500) { incoming?(.progress(id, ProgressPhase(kind: .copying))) }
            measured.value = client.inboxTrafficCount
        }
        let held = client.send(.runtimeVersion)
        for _ in 0..<400 where measured.value == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(measured.value == RuntimeClient.inboxTrafficLimit, "traffic the client has not reached yet is bounded at ingress")
        _ = held
    }

    @Test func aReplyThatArrivesAfterCancellationReleasesItsKey() async throws {
        let transport = FakeTransport(.acceptLater)
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.runtimeVersion)
        let consumer = Task { for try await _ in stream {} }
        for _ in 0..<400 where transport.sentCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        _ = try? await consumer.value
        try await Task.sleep(for: .milliseconds(50))
        transport.failPendingReply()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await client.settledKeyCount() == 0, "a request answered after its stream ended is not remembered for the life of the client")
    }

    @Test func aCancellationRacingTheTerminalEventLeavesNothingBehind() async throws {
        let transport = FakeTransport(.acceptLater)
        let client = RuntimeClient(transport: transport)
        let stream = client.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let received = Box<String>()
        let consumer = Task { for try await event in stream { received.value = event.caseName } }
        for _ in 0..<400 where transport.sentCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        transport.deliverPendingAccept()
        // The consumer has its acceptance and is waiting on the stream, so cancelling it below
        // reports a cancellation rather than a stream that simply ended.
        for _ in 0..<400 where received.value == nil { try await Task.sleep(for: .milliseconds(5)) }
        let id = try #require(transport.lastAcceptedID)
        transport.beforeSend = {
            let incoming = transport.lock.withLock { transport.incoming }
            // Both are enqueued while the client is inside this send, so the operation's last
            // event is handled first and the cancellation arrives behind it.
            incoming?(.completed(id))
            consumer.cancel()
        }
        let held = client.send(.runtimeVersion)
        for _ in 0..<400 where await client.isRetired(id) == false { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await client.abandonedKeyCount() == 0, "a cancellation that lost the race to the terminal event is not held forever")
        _ = held
    }

    @Test func retiredOperationIDsAreClearedWhenTheSessionEnds() async throws {
        let transport = FakeTransport(.acceptThenStream([.completed(OperationID())]))
        let client = RuntimeClient(transport: transport)
        let events = try await collect(client.send(.startEnvironment(EnvironmentID(), StartOptions())))
        guard case .accepted(let id)? = events.first else {
            Issue.record("no accepted event")
            return
        }
        #expect(await client.isRetired(id))
        transport.lock.withLock { transport.interrupted }?()
        for _ in 0..<400 where await client.isRetired(id) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await client.isRetired(id) == false, "a new session does not carry the previous session's ids")
    }

    @Test func anInterruptedMutationIsNeverOfferedABlindRetry() async throws {
        let mutating = RuntimeClient(transport: FakeTransport(.fail))
        var caught: RuntimeConnectionInterrupted?
        do {
            for try await _ in mutating.send(.startEnvironment(EnvironmentID(), StartOptions())) {}
        } catch let error as RuntimeConnectionInterrupted {
            caught = error
        }
        #expect(caught?.recoveryActions == [.inspectState, .cancel], "a mutation that may have reached the service is inspected, not repeated")
        #expect(caught?.userMessage.contains("may or may not") == true)

        let query = RuntimeClient(transport: FakeTransport(.fail))
        var queryError: RuntimeConnectionInterrupted?
        do {
            for try await _ in query.send(.runtimeVersion) {}
        } catch let error as RuntimeConnectionInterrupted {
            queryError = error
        }
        #expect(queryError?.recoveryActions == [.retry], "a read-only query changed nothing and may be asked again")
    }
}

/// A session that answers no send, either by throwing or by failing the reply, so the
/// transport's reconnect rules can be exercised without a live XPC connection.
final class RefusingSession: RuntimeSessionHandle, @unchecked Sendable {
    /// How the send is refused: synchronously, or through the reply an interrupted connection
    /// or an undecodable answer would deliver.
    enum Refusal { case throwOnSend, failTheReply }
    struct Refused: Error {}
    private let lock = NSLock()
    private var reasons: [String] = []
    let refusal: Refusal
    var cancelReasons: [String] { lock.withLock { reasons } }

    init(_ refusal: Refusal = .throwOnSend) { self.refusal = refusal }

    func sendEnvelope(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws {
        switch refusal {
        case .throwOnSend: throw Refused()
        case .failTheReply: reply(.failure(CocoaError(.xpcConnectionInterrupted)))
        }
    }

    func cancel(reason: String) { lock.withLock { reasons.append(reason) } }
}

/// Every session the transport opened.
final class OpenedSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [RefusingSession] = []
    var all: [RefusingSession] { lock.withLock { opened } }

    func open(_ refusal: RefusingSession.Refusal = .throwOnSend) -> RefusingSession {
        let session = RefusingSession(refusal)
        lock.withLock { opened.append(session) }
        return session
    }
}

@Suite struct XPCRuntimeTransportTests {
    @Test func aSessionThatRefusedASendIsNotHandedToTheNextRequest() {
        let sessions = OpenedSessions()
        let transport = XPCRuntimeTransport(connect: { _, _ in sessions.open() })
        let interruptions = Counter()
        transport.setHandlers(incoming: { _ in }, interrupted: { interruptions.increment() })
        for _ in 0..<2 {
            #expect(throws: RefusingSession.Refused.self) {
                try transport.send(RuntimeRequestEnvelope(request: .runtimeVersion)) { _ in }
            }
        }
        #expect(sessions.all.count == 2, "the refused session was retired rather than reused")
        #expect(sessions.all.first?.cancelReasons == ["send failed"])
        #expect(interruptions.value == 2, "each lost session reported its interruption once")
    }

    /// A reply that fails is the other way a session says it produced no answer, and an
    /// undecodable reply never triggers the cancellation handler that would retire it.
    @Test func aSessionWhoseReplyFailedIsNotHandedToTheNextRequest() {
        let sessions = OpenedSessions()
        let transport = XPCRuntimeTransport(connect: { _, _ in sessions.open(.failTheReply) })
        let interruptions = Counter()
        let failures = Counter()
        transport.setHandlers(incoming: { _ in }, interrupted: { interruptions.increment() })
        for _ in 0..<2 {
            #expect(throws: Never.self) {
                try transport.send(RuntimeRequestEnvelope(request: .runtimeVersion)) { result in
                    if case .failure = result { failures.increment() }
                }
            }
        }
        #expect(sessions.all.count == 2, "the session that failed a reply was retired rather than reused")
        #expect(sessions.all.first?.cancelReasons == ["reply failed"])
        #expect(interruptions.value == 2, "every operation on the lost session was told once")
        #expect(failures.value == 2, "the caller still receives its failure")
    }
}

/// The transport's session rules, exercised without a live XPC connection.
@Suite struct SessionRegistryTests {
    /// Collects a `Result` handed to a reply callback.
    private func delivered(_ registry: SessionRegistry<NSObject>, _ result: Result<RuntimeEvent, any Error>, from generation: Int) -> Result<RuntimeEvent, any Error>? {
        let box = Box<Result<RuntimeEvent, any Error>>()
        registry.deliverReply(result, from: generation) { box.value = $0 }
        return box.value
    }

    @Test func aReplyFromARetiredSessionBecomesAnInterruption() {
        let registry = SessionRegistry<NSObject>()
        let (_, generation) = registry.session { _ in NSObject() }
        guard case .success? = delivered(registry, .success(.accepted(OperationID())), from: generation) else {
            Issue.record("the live session's reply was not forwarded")
            return
        }
        _ = registry.retire(generation)
        guard case .failure(let error)? = delivered(registry, .success(.accepted(OperationID())), from: generation) else {
            Issue.record("an accepted reply from a retired session was forwarded")
            return
        }
        #expect(error is RuntimeConnectionInterrupted)
    }

    @Test func aSessionIsRetiredOnce() {
        let registry = SessionRegistry<NSObject>()
        let (_, generation) = registry.session { _ in NSObject() }
        let reports = Counter()
        registry.setHandlers(incoming: { _ in }, interrupted: { reports.increment() })
        _ = registry.retire(generation)
        #expect(reports.value == 1)
        _ = registry.retire(generation)
        #expect(reports.value == 1, "a second failure of the same session reports nothing")
    }

    @Test func aRetirementIsReportedBeforeAReplacementSessionExists() {
        let registry = SessionRegistry<NSObject>()
        let (_, generation) = registry.session { _ in NSObject() }
        let order = Order()
        registry.setHandlers(
            incoming: { _ in },
            interrupted: {
                // A replacement is only made by taking the registry's lock, so a request
                // racing this report has to wait for it. Without that ordering the
                // replacement's operations are failed by an interruption that predates them.
                DispatchQueue.global().async {
                    _ = registry.session { _ in NSObject() }
                    order.append("replacement")
                }
                Thread.sleep(forTimeInterval: 0.05)
                order.append("interrupted")
            }
        )
        _ = registry.retire(generation)
        for _ in 0..<200 where order.entries.count < 2 { Thread.sleep(forTimeInterval: 0.005) }
        #expect(order.entries == ["interrupted", "replacement"])
    }

    @Test func aRetirementCannotOvertakeAReplyBeingDelivered() {
        let registry = SessionRegistry<NSObject>()
        let (_, generation) = registry.session { _ in NSObject() }
        let retired = DispatchSemaphore(value: 0)
        registry.setHandlers(incoming: { _ in }, interrupted: {})
        registry.deliverReply(.success(.accepted(OperationID())), from: generation) { _ in
            DispatchQueue.global().async {
                _ = registry.retire(generation)
                retired.signal()
            }
            // The gate check and the handoff to the client are one step: an interruption can
            // never be enqueued in front of a reply that was already gated as live, which
            // would leave the accepted operation registered on a dead session forever.
            #expect(retired.wait(timeout: .now() + .milliseconds(300)) == .timedOut)
        }
        #expect(retired.wait(timeout: .now() + .seconds(5)) == .success)
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
