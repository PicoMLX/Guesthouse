import Foundation
import GuesthouseCore

/// Identity for one consumer stream, so its termination can be matched to the operation.
nonisolated final class ContinuationKey: Sendable {
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
        case send(RuntimeRequest, Continuation, ObjectIdentifier)
        case reply(Result<RuntimeEvent, any Error>, Continuation, ObjectIdentifier)
        case incoming(RuntimeEvent)
        case interrupted
        case consumerGone(ObjectIdentifier)
    }

    private let transport: any RuntimeTransport
    private var operations: [OperationID: Continuation] = [:]
    /// Events that arrived for an operation before its `accepted` reply registered a consumer.
    private var pendingEvents: [OperationID: [RuntimeEvent]] = [:]
    /// Which accepted operation each consumer stream owns, keyed by the stream's identity.
    private var consumers: [ObjectIdentifier: OperationID] = [:]
    /// Consumers that went away before their `accepted` reply arrived; the operation is
    /// canceled the moment it is accepted.
    private var abandonedBeforeAccept: Set<ObjectIdentifier> = []
    /// Operations whose consumer left; their late events are dropped, not kept. Bounded.
    private var retired: [OperationID] = []
    /// Keys whose request finished without acceptance (a query reply or a failure), so a
    /// late `consumerGone` for them is ignored. Bounded like `retired`.
    private var settled: Set<ObjectIdentifier> = []
    static let retiredLimit = 256
    private let inbox: AsyncStream<Inbound>
    private let inboxContinuation: AsyncStream<Inbound>.Continuation
    private var started = false

    /// Events buffered for one consumer before it reads them. Progress and log traffic beyond
    /// this drops the oldest entries; the terminal event is always the newest, so it survives.
    static let consumerBufferLimit = 1_024

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
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(Self.consumerBufferLimit)) { continuation in
            let key = ContinuationKey()
            continuation.onTermination = { [inboxContinuation] termination in
                if case .cancelled = termination {
                    inboxContinuation.yield(.consumerGone(ObjectIdentifier(key)))
                }
            }
            inboxContinuation.yield(.send(request, continuation, ObjectIdentifier(key)))
            Task { await self.startIfNeeded() }
        }
    }

    private func start(_ request: RuntimeRequest, _ continuation: Continuation, key: ObjectIdentifier) {
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
        case .consumerGone(let continuation): consumerGone(continuation)
        }
    }

    private func handleReply(_ result: Result<RuntimeEvent, any Error>, for continuation: Continuation, key: ObjectIdentifier) {
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

    private func settle(_ key: ObjectIdentifier) {
        settled.insert(key)
        if settled.count > Self.retiredLimit { settled.removeAll() }
    }

    private func retire(_ id: OperationID) {
        retired.append(id)
        if retired.count > Self.retiredLimit { retired.removeFirst(retired.count - Self.retiredLimit) }
    }

    /// Progress and log traffic may be evicted from a full consumer buffer; the operation's
    /// `accepted` event never is. If the buffer drops it, it is yielded again at once, so a
    /// consumer always learns the operation id even behind a flood.
    private func deliver(_ event: RuntimeEvent, to continuation: Continuation, id: OperationID) {
        if case .dropped(.accepted) = continuation.yield(event) {
            continuation.yield(.accepted(id))
        }
    }

    private func route(_ event: RuntimeEvent) {
        switch event {
        case .progress(let id, _), .log(let id?, _):
            if let continuation = operations[id] {
                deliver(event, to: continuation, id: id)
            } else if !retired.contains(id) {
                pendingEvents[id, default: []].append(event)
            }
        case .completed(let id), .failed(let id, _):
            if let continuation = operations.removeValue(forKey: id) {
                consumers = consumers.filter { $0.value != id }
                continuation.yield(event)
                continuation.finish()
            } else if !retired.contains(id) {
                pendingEvents[id, default: []].append(event)
            }
        case .status, .runtimeVersion, .accepted, .log(nil, _):
            for continuation in operations.values { continuation.yield(event) }
        }
    }

    private func consumerGone(_ key: ObjectIdentifier) {
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
        for (id, continuation) in pending {
            continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
        }
        consumers.removeAll()
    }
}
