import Foundation
import GuesthouseCore
import Synchronization

/// Identity for one consumer stream, so its termination can be matched to the operation.
nonisolated final class ContinuationKey: Hashable, Sendable {
    static func == (lhs: ContinuationKey, rhs: ContinuationKey) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// How much droppable traffic the client's inbox is holding.
///
/// The limits that protect a consumer's stream apply only once an event has been dequeued, so
/// without a bound here output the service produces faster than the actor drains it would grow
/// the app's memory without limit and delay replies, cancellation and interruption behind it.
/// Control events are never counted and never refused: they have to stay ordered.
nonisolated final class TrafficMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = 0
    private var held: [RuntimeEvent] = []
    private let limit: Int
    private let tailLimit: Int

    init(limit: Int, tailLimit: Int) {
        self.limit = limit
        self.tailLimit = tailLimit
    }

    /// Takes a slot for one droppable event, or holds it as part of a bounded newest tail when
    /// the inbox already holds the limit. Returns whether the caller may enqueue it now.
    ///
    /// Refusing outright threw away exactly the end of a log: a service that outruns the actor
    /// for the rest of an operation had every event after saturation dropped here, so the
    /// window handed over when the operation ended could only be chosen from the older
    /// admitted prefix — the tail the whole reserve exists for was never in the client at all.
    /// Once anything is held, everything droppable is, so what a consumer sees stays in the
    /// order the service produced it.
    func admit(_ event: RuntimeEvent) -> Bool {
        lock.withLock {
            guard held.isEmpty, queued < limit else {
                hold(event)
                return false
            }
            queued += 1
            return true
        }
    }

    /// Takes the whole backlog, counting each event as queued again: it is on its way to the
    /// inbox and `release` balances it there like any other admitted event.
    func takeHeld() -> [RuntimeEvent] {
        lock.withLock {
            let backlog = held
            held.removeAll()
            queued += backlog.count
            return backlog
        }
    }

    /// Returns the slot of an event the client has finished routing.
    func release() { lock.withLock { queued -= 1 } }

    var queuedCount: Int { lock.withLock { queued } }

    /// How much of the newest tail is waiting for a control event to carry it in. Test seam.
    var heldCount: Int { lock.withLock { held.count } }

    /// Keeps the newest `tailLimit` refused events. A log line is what the tail is kept for,
    /// so a progress or status report is given up before one is.
    private func hold(_ event: RuntimeEvent) {
        held.append(event)
        guard held.count > tailLimit else { return }
        let oldest = held.firstIndex { if case .log = $0 { false } else { true } } ?? held.startIndex
        held.remove(at: oldest)
    }
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
        /// `mutating` records whether the request changes host state, which decides what an
        /// interruption before acceptance may offer the user.
        case reply(Result<RuntimeEvent, any Error>, Continuation, ContinuationKey, mutating: Bool)
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
    /// How many operations may hold such a buffer at once.
    ///
    /// Each bucket is only ever justified by a request that has not been answered yet, since
    /// that is the only thing an acceptance can follow; the per-id cap above says nothing
    /// about how many ids there are, and terminal events are never refused at ingress. Without
    /// this a service streaming events for ids nothing asked for would grow the dictionary
    /// itself. It is far above the operations one app runs at a time (MVP-PLAN.md §6,
    /// "Concurrency"), so an honest runtime never reaches it.
    static let pendingOperationLimit = 64
    /// Requests sent and not yet answered. An `accepted` can only ever come from one of these,
    /// so while there are none, an event naming an unknown operation belongs to nothing.
    private var awaitingReply = 0
    private let inbox: AsyncStream<Inbound>
    private let inboxContinuation: AsyncStream<Inbound>.Continuation
    private var started = false

    /// How many events one consumer's stream buffers. The client drops its own excess before
    /// the stream is full, so control events (`accepted` and the terminal event) are never
    /// lost and never reordered behind droppable traffic a consumer is not reading.
    static let consumerBufferLimit = 1_024
    /// Slots of that buffer kept free for control events: droppable traffic stops here.
    static let consumerControlReserve = 64
    /// Slots kept free on top of that for the newest events handed over when the operation
    /// ends. A log is read for its tail, so the client stops delivering droppable traffic
    /// early enough that the whole window a consumer keeps still fits at the end; without it
    /// the tail is only whatever room the probes happened to leave, and the window a consumer
    /// retains is a few dozen recent lines followed by much older ones.
    static let consumerTailReserve = 512
    /// The room below which droppable traffic is held instead of yielded.
    static var trafficFloor: Int { consumerControlReserve + consumerTailReserve }
    /// The room below which even the probes stop. A probe occupies a slot like any other
    /// yield, so one that keeps going past this spends the tail it is measuring for.
    static var probeFloor: Int { terminalReserve + consumerTailReserve }
    /// While traffic is being dropped, one event in this many is delivered anyway. A yield is
    /// the only report of how much room a consumer has left, so without this probe a consumer
    /// that fell behind once would never receive traffic again for the rest of the operation.
    static let trafficProbeInterval = 64
    /// Slots of the buffer only an event that ends the stream may occupy. Every other yield
    /// stops here — traffic, the probes that measure the room left, and status snapshots
    /// alike — so the terminal event a consumer waits for always finds a slot, however far
    /// behind that consumer is. It is a few slots rather than one because the `accepted`
    /// event is yielded before the stream is tracked, so the recorded room can briefly
    /// overstate the real room by that much.
    static let terminalReserve = 4
    /// How much droppable traffic the inbox holds before further traffic is refused at
    /// ingress. Large enough that a consumer reading in real time never notices it.
    static let inboxTrafficLimit = 4_096
    /// Room left in each consumer's stream, as of its last yield.
    private var consumerRoom: [OperationID: Int] = [:]
    private var droppedSinceProbe: [OperationID: Int] = [:]
    /// Traffic held while there was no room, newest kept and handed over when the operation ends.
    private var heldTraffic: [OperationID: [RuntimeEvent]] = [:]
    private let traffic = TrafficMeter(limit: RuntimeClient.inboxTrafficLimit, tailLimit: RuntimeClient.consumerTailReserve)

    /// How much droppable traffic is waiting in the inbox. Test seam; readable without the
    /// actor, so it can be sampled while the actor is busy routing.
    nonisolated var inboxTrafficCount: Int { traffic.queuedCount }

    /// How much traffic the ingress is holding past its bound, waiting for a control event to
    /// carry it in ahead of itself. Test seam, readable for the same reason.
    nonisolated var ingressTailCount: Int { traffic.heldCount }

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
        // Whether the request changes the host travels with its reply: once the reply fails
        // there is no operation id to say so, and a mutating request that may already have
        // reached the service must never be offered a blind retry.
        let mutating = request.mutatesHost
        awaitingReply += 1
        do {
            try transport.send(RuntimeRequestEnvelope(request: request)) { [inboxContinuation] result in
                inboxContinuation.yield(.reply(result, continuation, key, mutating: mutating))
            }
        } catch {
            // The failure takes the ordered path a reply would, so a `consumerGone` queued
            // behind this send finds its key settled instead of marking it abandoned forever.
            inboxContinuation.yield(.reply(.failure(error), continuation, key, mutating: mutating))
        }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        let inboxContinuation = inboxContinuation
        let traffic = traffic
        transport.setHandlers(
            // Traffic is bounded where it is enqueued, not only where it is delivered: a
            // service producing output faster than the actor drains it loses the excess here
            // instead of growing the inbox. Control events are always admitted, so acceptance,
            // the terminal event and an interruption keep their order.
            incoming: { event in
                if event.isDroppableTraffic {
                    guard traffic.admit(event) else { return }
                    inboxContinuation.yield(.incoming(event))
                    return
                }
                // A control event never waits, but the traffic the ingress is holding is older
                // than it and belongs in front of it: the tail of an operation's log goes in
                // ahead of the terminal event that ends its stream, rather than being thrown
                // away once that stream has finished.
                for backlog in traffic.takeHeld() { inboxContinuation.yield(.incoming(backlog)) }
                inboxContinuation.yield(.incoming(event))
            },
            // The lines written just before a connection was lost are the ones that explain
            // it, so they are carried in ahead of the interruption for the same reason.
            interrupted: {
                for backlog in traffic.takeHeld() { inboxContinuation.yield(.incoming(backlog)) }
                inboxContinuation.yield(.interrupted)
            }
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
        case .reply(let result, let continuation, let key, let mutating):
            handleReply(result, for: continuation, key: key, mutating: mutating)
        case .incoming(let event):
            route(event)
            // The slot this event took at ingress is returned once it has been routed, so the
            // bound tracks what the client is actually holding.
            if event.isDroppableTraffic { traffic.release() }
        case .interrupted: connectionDropped()
        case .consumerGone(let key): consumerGone(key)
        case .streamFinished(let key): streamFinished(key)
        }
    }

    private func handleReply(_ result: Result<RuntimeEvent, any Error>, for continuation: Continuation, key: ContinuationKey, mutating: Bool) {
        // Exactly one reply arrives per request, whether the transport answered it or refused
        // the send outright. `max` keeps the count meaningful if a session is ever lost
        // without delivering one: the bound may loosen, never invert.
        awaitingReply = max(0, awaitingReply - 1)
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
            case .runtimeVersion, .environments, .xcodeCandidate, .status, .completed, .failed, .progress, .log:
                settle(key)
                continuation.finish()
            }
        case .failure:
            settle(key)
            // No operation id: the request was never accepted. A read-only query changed
            // nothing and may simply be asked again, but a mutating request may already have
            // reached the service and been journaled or started, so its outcome is unknown
            // and the user is sent to inspect state rather than offered a retry.
            continuation.finish(throwing: RuntimeConnectionInterrupted(mayHaveMutated: mutating))
        }
    }

    /// How many events are held for an operation that has not been accepted. Test seam.
    func pendingEventCount(for id: OperationID) -> Int { pendingEvents[id]?.count ?? 0 }

    /// How many operations hold such a buffer. Test seam.
    func pendingOperationCount() -> Int { pendingEvents.count }

    /// How many finished requests are still held against a cancellation race. Test seam.
    func settledKeyCount() -> Int { settled.count }

    /// How many consumers left before their request was accepted. Test seam.
    func abandonedKeyCount() -> Int { abandonedBeforeAccept.count }

    /// Whether an operation has ended, so nothing more will be delivered for it. Test seam.
    func isRetired(_ id: OperationID) -> Bool { retired.contains(id) }

    /// Remembers a key whose request was answered without acceptance, so a cancellation still
    /// racing that reply is recognised instead of being mistaken for an operation that was
    /// never accepted.
    ///
    /// A key whose stream has already terminated is not remembered: its `consumerGone` has
    /// been handled, nothing further will arrive for it, and `finish` on an ended continuation
    /// produces no second termination to release it. Remembering it would hold one key per
    /// canceled request for the life of the client.
    private func settle(_ key: ContinuationKey) {
        guard abandonedBeforeAccept.remove(key) == nil else { return }
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
        // Nobody is left to hand the backlog to. An operation whose consumer walked away, or
        // whose stream this retirement is ending, would otherwise keep up to
        // `consumerBufferLimit` events for the life of the client, and repeated canceled
        // high-output operations would grow it without bound.
        heldTraffic.removeValue(forKey: id)
    }

    /// Releases the consumer keys of an operation that has ended. They become settled rather
    /// than forgotten, so a cancellation that was already racing the operation's last event is
    /// recognised as arriving after the fact; a forgotten key would instead be remembered as
    /// an acceptance that never came, and nothing would ever release it.
    private func retireConsumers(of id: OperationID) {
        for key in consumers.filter({ $0.value == id }).keys {
            consumers.removeValue(forKey: key)
            settled.insert(key)
        }
    }

    /// Droppable traffic: progress and log lines. It is delivered while the consumer's stream
    /// has room beyond the reserve, so the control events (`accepted` and the terminal event)
    /// can never be crowded out or reordered behind traffic nobody is reading. The room is
    /// what the stream reports, not a count of everything ever sent, so a consumer keeping up
    /// in real time is never cut off.
    private func deliver(_ event: RuntimeEvent, to continuation: Continuation, id: OperationID) {
        if consumerRoom[id, default: Self.consumerBufferLimit] <= Self.trafficFloor {
            hold(event, for: id)
            let dropped = droppedSinceProbe[id, default: 0] + 1
            guard dropped >= Self.trafficProbeInterval else {
                droppedSinceProbe[id] = dropped
                return
            }
            droppedSinceProbe[id] = 0
            // Probe: the stream refuses a yield it has no room for, so this measures the room
            // again without displacing anything already queued. It hands over the oldest held
            // event rather than this one, so measuring can never put a newer line in front of
            // one the consumer has not been given yet.
            releaseOldestHeldTraffic(of: id, to: continuation)
            return
        }
        // The consumer has room again, but a probe may have opened that room while most of
        // the backlog is still held. Delivering this event directly would put a newer line in
        // front of older ones the consumer has not been given, and the terminal flush would
        // then append that older backlog behind it: the log would go backwards, and the
        // newest-line window a reader keeps would no longer be the newest lines. So this
        // event joins the queue and the queue is drained in order.
        guard heldTraffic[id] == nil else {
            hold(event, for: id)
            drainHeldTraffic(of: id, to: continuation)
            return
        }
        yieldNonTerminal(event, to: continuation, id: id)
    }

    /// Hands the backlog over oldest first while the consumer keeps room beyond the floor.
    /// What does not fit stays held, so a consumer that only partly caught up falls back to
    /// the same holding and probing as before rather than losing the rest of its backlog.
    private func drainHeldTraffic(of id: OperationID, to continuation: Continuation) {
        while consumerRoom[id, default: Self.consumerBufferLimit] > Self.trafficFloor,
              var held = heldTraffic[id], !held.isEmpty {
            let oldest = held.removeFirst()
            heldTraffic[id] = held.isEmpty ? nil : held
            yieldTracking(oldest, to: continuation, id: id)
        }
    }

    /// Yields and records the room the stream reports it has left, which is how a consumer
    /// that has caught up is noticed.
    /// What was held back while the consumer had no room, newest kept. A log is read for its
    /// tail, so an operation that outruns a slow reader still hands over its last events when
    /// it ends rather than leaving the reader with only the beginning.
    private func hold(_ event: RuntimeEvent, for id: OperationID) {
        var held = heldTraffic[id] ?? []
        held.append(event)
        if held.count > Self.consumerBufferLimit { held.remove(at: Self.oldestDroppable(in: held)) }
        heldTraffic[id] = held
    }

    /// Which held event to give up first: the oldest progress or status report, and only when
    /// there is none, the oldest log line. What a consumer keeps is a count of *lines*, so
    /// counting every event alike would let a busy operation's progress traffic push the
    /// newest lines out of the window while the reserve still looked full.
    private static func oldestDroppable(in held: [RuntimeEvent]) -> Int {
        held.firstIndex { if case .log = $0 { false } else { true } } ?? held.startIndex
    }

    /// The newest `room` held events in arrival order, choosing log lines over the progress
    /// and status reports interleaved with them. The tail reserve is sized for the window a
    /// reader keeps, which is a count of lines, so trimming by raw event count would hand
    /// over a window holding far fewer lines than that reserve was meant to guarantee.
    private static func newestTail(of held: [RuntimeEvent], fitting room: Int) -> [RuntimeEvent] {
        guard held.count > room else { return held }
        var keep = [Bool](repeating: false, count: held.count)
        var remaining = room
        for index in held.indices.reversed() where remaining > 0 {
            guard case .log = held[index] else { continue }
            keep[index] = true
            remaining -= 1
        }
        for index in held.indices.reversed() where remaining > 0 {
            guard !keep[index] else { continue }
            keep[index] = true
            remaining -= 1
        }
        return held.indices.filter { keep[$0] }.map { held[$0] }
    }

    /// Hands over one held event, oldest first. Used as the probe, so the measurement carries
    /// the log forward in order instead of jumping ahead of it.
    private func releaseOldestHeldTraffic(of id: OperationID, to continuation: Continuation) {
        // A probe is droppable traffic like every other yield, and it stops at the tail the
        // operation's end has to fit through, not at the terminal event's own few slots.
        // Probing all the way down spends the very window `consumerTailReserve` exists to
        // guarantee: one probe per 64 dropped events walks the room from the floor to four,
        // so after roughly 36,000 held events the newest-500 window a reader keeps becomes an
        // old prefix with about three recent lines behind it.
        guard consumerRoom[id, default: Self.consumerBufferLimit] > Self.probeFloor else { return }
        guard var held = heldTraffic[id], !held.isEmpty else { return }
        let oldest = held.removeFirst()
        heldTraffic[id] = held.isEmpty ? nil : held
        yieldTracking(oldest, to: continuation, id: id)
    }

    /// Hands over as much of the held tail as the stream can still take, newest first in order,
    /// before the terminal event. The terminal event has to fit after this, or the consumer
    /// would never learn the operation ended.
    private func flushHeldTraffic(of id: OperationID, to continuation: Continuation) {
        guard var held = heldTraffic.removeValue(forKey: id), !held.isEmpty else { return }
        let room = max(consumerRoom[id, default: Self.consumerBufferLimit] - 1, 0)
        held = Self.newestTail(of: held, fitting: room)
        for event in held {
            guard consumerRoom[id, default: Self.consumerBufferLimit] > 1 else { return }
            yieldTracking(event, to: continuation, id: id)
        }
    }

    /// Yields an event that does not end the stream, and only while the room left is beyond
    /// the slots kept for one that does.
    ///
    /// A probe occupies a slot of the buffer like any other yield, so without this floor a
    /// consumer that stops reading has its whole control reserve consumed by probes and status
    /// snapshots; the terminal event is then refused by the full buffer and its stream ends
    /// with no result at all. The recorded room can only be stale in the safe direction — a
    /// consumer that reads leaves more room, never less — so room above the floor means the
    /// terminal yield is certain to find a slot.
    private func yieldNonTerminal(_ event: RuntimeEvent, to continuation: Continuation, id: OperationID) {
        guard consumerRoom[id, default: Self.consumerBufferLimit] > Self.terminalReserve else { return }
        yieldTracking(event, to: continuation, id: id)
    }



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
                retireConsumers(of: id)
                flushHeldTraffic(of: id, to: continuation)
                continuation.yield(event)
                continuation.finish()
                // The operation is over: anything that arrives for it afterwards is dropped
                // rather than buffered for an acceptance that will never come again.
                retire(id)
            } else if !retired.contains(id) {
                append(event, for: id)
            }
        case .status(let status):
            // A snapshot that names the operation it belongs to is that operation's event:
            // each stream carries the events of its own request (`RuntimeBackend.send`), and
            // one that arrives before the `accepted` reply waits in the same bounded buffer
            // the operation's progress does instead of being lost. A snapshot that names no
            // operation describes the environment rather than any one request, so it still
            // reaches every stream.
            //
            // Either way a snapshot is superseded by the next one, so it takes the bounded
            // delivery path: a consumer that is not reading loses snapshots rather than the
            // room its terminal event needs.
            if let owner = status.inFlightOperation {
                if let continuation = operations[owner] {
                    deliver(event, to: continuation, id: owner)
                } else if !retired.contains(owner) {
                    append(event, for: owner)
                }
            } else {
                for (id, continuation) in operations { deliver(event, to: continuation, id: id) }
            }
        case .runtimeVersion, .environments, .xcodeCandidate, .accepted:
            for (id, continuation) in operations { yieldNonTerminal(event, to: continuation, id: id) }
        case .log(nil, _):
            // Unscoped guest output is droppable traffic for every operation, not a control
            // event: it takes the bounded path too, so high-volume output cannot accumulate
            // in the stream of a consumer that is not reading.
            for (id, continuation) in operations { deliver(event, to: continuation, id: id) }
        }
    }

    /// Buffers an event for an operation that has not been accepted yet, bounded per operation
    /// and in the number of operations.
    private func append(_ event: RuntimeEvent, for id: OperationID) {
        if pendingEvents[id] == nil {
            // Nothing can ever accept this id unless a request is still unanswered, and only
            // so many buffers are worth holding even then, so a stream of ids the app never
            // asked for is dropped here instead of taking a buffer of its own.
            guard awaitingReply > 0, pendingEvents.count < Self.pendingOperationLimit else { return }
        }
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

    /// Held outside the actor so a subscription is complete when `connectionInterruptions()`
    /// returns: a registration deferred to a task could miss the very first loss, and a
    /// cached Ready would then never be re-checked.
    private nonisolated let interruptionObservers = Mutex<[AsyncStream<RuntimeConnectionInterrupted>.Continuation]>([])

    /// How many observers are registered. Test seam for the registration guarantee above.
    nonisolated var interruptionObserverCount: Int { interruptionObservers.withLock { $0.count } }

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

    nonisolated func connectionInterruptions() -> AsyncStream<RuntimeConnectionInterrupted> {
        AsyncStream { continuation in
            interruptionObservers.withLock { $0.append(continuation) }
        }
    }

    private func connectionDropped() {
        for observer in interruptionObservers.withLock({ $0 }) { observer.yield(RuntimeConnectionInterrupted()) }
        let pending = operations
        operations.removeAll()
        pendingEvents.removeAll()
        consumerRoom.removeAll()
        droppedSinceProbe.removeAll()
        // The streams these backlogs were being kept for are all about to be finished with an
        // interruption, so nothing will ever hand them over; left here they would be one
        // buffer per operation held for the rest of the app's life.
        heldTraffic.removeAll()
        // Every id these hold belonged to the session that just ended, and the registry
        // already refuses that session's callbacks, so nothing can still arrive for them.
        // Keeping them would hold one id per operation for the rest of the app's life.
        retired.removeAll()
        for (id, continuation) in pending {
            retireConsumers(of: id)
            continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
        }
    }
}

nonisolated extension RuntimeEvent {
    /// Ends an operation. A consumer that never receives one waits forever, so these events
    /// are never dropped to make room for traffic.
    fileprivate var endsOperation: Bool {
        switch self {
        case .completed, .failed: true
        case .runtimeVersion, .environments, .xcodeCandidate, .accepted, .progress, .log, .status: false
        }
    }

    /// Detail the client may drop. Only the replies to a query, `accepted` and the terminal
    /// events say what happened to a request; progress, log lines and status snapshots are what
    /// a consumer that has fallen behind loses first, so they are also what the inbox refuses
    /// when it is full. `environments` answers `listEnvironments` exactly as `runtimeVersion`
    /// answers its own request: dropping it would leave the caller waiting for a reply that
    /// has already been thrown away.
    fileprivate var isDroppableTraffic: Bool {
        switch self {
        case .progress, .log, .status: true
        case .runtimeVersion, .environments, .xcodeCandidate, .accepted, .completed, .failed: false
        }
    }
}
