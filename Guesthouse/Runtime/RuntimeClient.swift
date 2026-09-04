import Foundation
import GuesthouseCore

/// Identity for one consumer stream, so its termination can be matched to the operation.
nonisolated final class ContinuationKey: Hashable, Sendable {
    static func == (lhs: ContinuationKey, rhs: ContinuationKey) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The GUI's `RuntimeBackend` over XPC.
///
/// Connects lazily, maps a dropped connection to `RuntimeConnectionInterrupted` so callers
/// treat in-flight work as unknown outcome (MVP-PLAN.md §3), and reconnects on the next
/// request. Long-running operations stream their events through the transport's incoming
/// handler and are demultiplexed by `OperationID`.
///
/// Every transport callback (reply, pushed event, interruption) is enqueued synchronously on
/// one ordered inbox and applied by a single task, so callback order is preserved: an
/// interruption that follows an `accepted` reply always finds the operation registered.
actor RuntimeClient: RuntimeBackend {
    typealias Continuation = AsyncThrowingStream<RuntimeEvent, any Error>.Continuation

    private enum Inbound: Sendable {
        case send(RuntimeRequest, Continuation, ContinuationKey)
        case reply(Result<RuntimeEvent, any Error>, Continuation, ContinuationKey)
        case incoming(RuntimeEvent)
        case interrupted
        case consumerGone(ContinuationKey)
        case streamFinished(ContinuationKey)
    }

    private let transport: any RuntimeTransport
    private var operations: [OperationID: Continuation] = [:]
    /// Events that arrived for an operation before its `accepted` reply registered a consumer.
    private var pendingEvents: [OperationID: [RuntimeEvent]] = [:]
    /// Which accepted operation each consumer stream owns. The key object itself is held, so
    /// an address freed and reused by a later stream can never be mistaken for this one.
    private var consumers: [ContinuationKey: OperationID] = [:]
    /// Consumers that went away before their `accepted` reply arrived; the operation is
    /// canceled the moment it is accepted.
    private var abandonedBeforeAccept: Set<ContinuationKey> = []
    /// Operations that have ended or whose consumer left: their late events are dropped, not
    /// kept. Held for the session, since an id is small and a forgotten one would let late
    /// guest output accumulate again.
    private var retired: Set<OperationID> = []
    /// Keys whose request finished without acceptance (a query reply or a failure), so a
    /// late `consumerGone` for them is ignored. A key is held only until its stream
    /// terminates, which is the last moment a cancellation can still race the reply.
    private var settled: Set<ContinuationKey> = []
    /// Buffered events per operation that has not been accepted yet, bounded so a runtime
    /// that streams before its reply cannot grow this without limit.
    static let pendingEventLimit = 256
    private let inbox: AsyncStream<Inbound>
    private let inboxContinuation: AsyncStream<Inbound>.Continuation
    private var started = false

    /// How many events one consumer's stream buffers. The client drops its own excess before
    /// the stream is full, so control events (`accepted` and the terminal event) are never
    /// lost and never reordered behind droppable traffic a consumer is not reading.
    static let consumerBufferLimit = 1_024
    /// Slots of that buffer kept free for control events: droppable traffic stops here.
    static let consumerControlReserve = 64
    /// While traffic is being dropped, one event in this many is delivered anyway. A yield is
    /// the only report of how much room a consumer has left, so without this probe a consumer
    /// that fell behind once would never receive traffic again for the rest of the operation.
    static let trafficProbeInterval = 64
    /// Room left in each consumer's stream, as of its last yield.
    private var consumerRoom: [OperationID: Int] = [:]
    private var droppedSinceProbe: [OperationID: Int] = [:]

    init(transport: any RuntimeTransport = XPCRuntimeTransport()) {
        self.transport = transport
        (inbox, inboxContinuation) = AsyncStream.makeStream(of: Inbound.self, bufferingPolicy: .unbounded)
    }

    deinit {
        // Ends the drain loop of a discarded client; it holds no strong reference to self.
        inboxContinuation.finish()
    }

    /// Requests are enqueued on the same ordered inbox as every callback, synchronously, so
    /// two back-to-back sends reach the transport in the order they were made. When the
    /// consumer stops reading an accepted operation, the client unregisters it and asks the
    /// runtime to cancel it, so a host mutation never keeps running unobserved.
    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        // The buffer is bounded and never evicts what it already holds: the client stops
        // delivering droppable traffic while the room left is down to the reserve, so a
        // control event always finds a slot even when a consumer stops reading entirely.
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.consumerBufferLimit)) { continuation in
            let key = ContinuationKey()
            // The termination closure holds the client, so a caller that keeps only the
            // stream still has a producer: the client is released when the stream ends.
            let owner = self
            continuation.onTermination = { [inboxContinuation] termination in
                withExtendedLifetime(owner) {
                    switch termination {
                    case .cancelled: inboxContinuation.yield(.consumerGone(key))
                    // The stream ended normally, so no cancellation can still race the reply
                    // and the key is no longer needed for anything.
                    default: inboxContinuation.yield(.streamFinished(key))
                    }
                }
            }
            inboxContinuation.yield(.send(request, continuation, key))
            Task { await self.startIfNeeded() }
        }
    }

    private func start(_ request: RuntimeRequest, _ continuation: Continuation, key: ContinuationKey) {
        do {
            try transport.send(RuntimeRequestEnvelope(request: request)) { [inboxContinuation] result in
                inboxContinuation.yield(.reply(result, continuation, key))
            }
        } catch {
            // The failure takes the ordered path a reply would, so a `consumerGone` queued
            // behind this send finds its key settled instead of marking it abandoned forever.
            inboxContinuation.yield(.reply(.failure(error), continuation, key))
        }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        let inboxContinuation = inboxContinuation
        transport.setHandlers(
            incoming: { event in inboxContinuation.yield(.incoming(event)) },
            interrupted: { inboxContinuation.yield(.interrupted) }
        )
        // The loop borrows `self` per item only, so a client nobody holds is released while
        // the loop waits, and `deinit` then ends the inbox.
        // The loop borrows the client per item only, so a client with no live streams is
        // released while the loop waits and `deinit` then ends the inbox. A live stream keeps
        // the client alive on its own (see `send`), so an accepted operation always has a
        // producer to finish it.
        let inbox = inbox
        Task { [weak self] in
            for await item in inbox {
                guard let self else { return }
                await self.handle(item)
            }
        }
    }

    private func handle(_ item: Inbound) {
        switch item {
        case .send(let request, let continuation, let key): start(request, continuation, key: key)
        case .reply(let result, let continuation, let key): handleReply(result, for: continuation, key: key)
        case .incoming(let event): route(event)
        case .interrupted: connectionDropped()
        case .consumerGone(let key): consumerGone(key)
        case .streamFinished(let key): streamFinished(key)
        }
    }

    private func handleReply(_ result: Result<RuntimeEvent, any Error>, for continuation: Continuation, key: ContinuationKey) {
        switch result {
        case .success(let event):
            continuation.yield(event)
            switch event {
            case .accepted(let id):
                if abandonedBeforeAccept.remove(key) != nil {
                    // The consumer left before acceptance: nobody observes this mutation, so
                    // it is canceled right away instead of running unobserved.
                    continuation.finish()
                    pendingEvents.removeValue(forKey: id)
                    retire(id)
                    try? transport.send(RuntimeRequestEnvelope(request: .cancelOperation(id))) { _ in }
                    return
                }
                // More events follow through the incoming handler until completed or failed.
                operations[id] = continuation
                consumers[key] = id
                for buffered in pendingEvents.removeValue(forKey: id) ?? [] {
                    route(buffered)
                }
            case .runtimeVersion, .status, .completed, .failed, .progress, .log:
                abandonedBeforeAccept.remove(key)
                settle(key)
                continuation.finish()
            }
        case .failure:
            abandonedBeforeAccept.remove(key)
            settle(key)
            continuation.finish(throwing: RuntimeConnectionInterrupted())
        }
    }

    /// How many events are held for an operation that has not been accepted. Test seam.
    func pendingEventCount(for id: OperationID) -> Int { pendingEvents[id]?.count ?? 0 }

    /// How many finished requests are still held against a cancellation race. Test seam.
    func settledKeyCount() -> Int { settled.count }

    /// Whether an operation has ended, so nothing more will be delivered for it. Test seam.
    func isRetired(_ id: OperationID) -> Bool { retired.contains(id) }

    private func settle(_ key: ContinuationKey) {
        settled.insert(key)
    }

    /// A stream that ended on its own can no longer produce a `consumerGone`, so everything
    /// remembered about it is released; otherwise one key per query would be held for the
    /// life of the client.
    private func streamFinished(_ key: ContinuationKey) {
        settled.remove(key)
        abandonedBeforeAccept.remove(key)
        consumers.removeValue(forKey: key)
    }

    private func retire(_ id: OperationID) {
        retired.insert(id)
        pendingEvents.removeValue(forKey: id)
        consumerRoom.removeValue(forKey: id)
        droppedSinceProbe.removeValue(forKey: id)
    }

    /// Droppable traffic: progress and log lines. It is delivered while the consumer's stream
    /// has room beyond the reserve, so the control events (`accepted` and the terminal event)
    /// can never be crowded out or reordered behind traffic nobody is reading. The room is
    /// what the stream reports, not a count of everything ever sent, so a consumer keeping up
    /// in real time is never cut off.
    private func deliver(_ event: RuntimeEvent, to continuation: Continuation, id: OperationID) {
        if consumerRoom[id, default: Self.consumerBufferLimit] <= Self.consumerControlReserve {
            let dropped = droppedSinceProbe[id, default: 0] + 1
            guard dropped >= Self.trafficProbeInterval else {
                droppedSinceProbe[id] = dropped
                return
            }
            // Probe: the stream refuses a yield it has no room for, so this measures the room
            // again without displacing anything already queued.
            droppedSinceProbe[id] = 0
        }
        yieldTracking(event, to: continuation, id: id)
    }

    /// Yields and records the room the stream reports it has left, which is how a consumer
    /// that has caught up is noticed.
    private func yieldTracking(_ event: RuntimeEvent, to continuation: Continuation, id: OperationID) {
        if case .enqueued(let remaining) = continuation.yield(event) {
            consumerRoom[id] = remaining
        } else {
            consumerRoom[id] = 0
        }
    }

    private func route(_ event: RuntimeEvent) {
        switch event {
        case .progress(let id, _), .log(let id?, _):
            if let continuation = operations[id] {
                deliver(event, to: continuation, id: id)
            } else if !retired.contains(id) {
                append(event, for: id)
            }
        case .completed(let id), .failed(let id, _):
            if let continuation = operations.removeValue(forKey: id) {
                consumers = consumers.filter { $0.value != id }
                continuation.yield(event)
                continuation.finish()
                // The operation is over: anything that arrives for it afterwards is dropped
                // rather than buffered for an acceptance that will never come again.
                retire(id)
            } else if !retired.contains(id) {
                append(event, for: id)
            }
        case .status, .runtimeVersion, .accepted:
            for (id, continuation) in operations { yieldTracking(event, to: continuation, id: id) }
        case .log(nil, _):
            // Unscoped guest output is droppable traffic for every operation, not a control
            // event: it takes the bounded path too, so high-volume output cannot accumulate
            // in the stream of a consumer that is not reading.
            for (id, continuation) in operations { deliver(event, to: continuation, id: id) }
        }
    }

    /// Buffers an event for an operation that has not been accepted yet, bounded.
    private func append(_ event: RuntimeEvent, for id: OperationID) {
        var events = pendingEvents[id] ?? []
        if events.count >= Self.pendingEventLimit {
            // The terminal event is what ends the consumer's stream: dropping it would leave
            // the caller waiting forever once the operation is finally accepted. Room is made
            // for it by dropping the oldest droppable event instead.
            guard event.endsOperation, let droppable = events.firstIndex(where: { !$0.endsOperation }) else { return }
            events.remove(at: droppable)
        }
        events.append(event)
        pendingEvents[id] = events
    }

    private func consumerGone(_ key: ContinuationKey) {
        guard let id = consumers.removeValue(forKey: key) else {
            // Already answered (a query or a failed send): nothing to cancel. Otherwise not
            // accepted yet: remembered until the reply says which it was.
            if settled.remove(key) == nil { abandonedBeforeAccept.insert(key) }
            return
        }
        guard operations.removeValue(forKey: id) != nil else { return }
        pendingEvents.removeValue(forKey: id)
        retire(id)
        try? transport.send(RuntimeRequestEnvelope(request: .cancelOperation(id))) { _ in }
    }

    private func connectionDropped() {
        let pending = operations
        operations.removeAll()
        pendingEvents.removeAll()
        consumerRoom.removeAll()
        droppedSinceProbe.removeAll()
        for (id, continuation) in pending {
            continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
        }
        consumers.removeAll()
    }
}

nonisolated extension RuntimeEvent {
    /// Ends an operation. A consumer that never receives one waits forever, so these events
    /// are never dropped to make room for traffic.
    fileprivate var endsOperation: Bool {
        switch self {
        case .completed, .failed: true
        case .runtimeVersion, .accepted, .progress, .log, .status: false
        }
    }
}
