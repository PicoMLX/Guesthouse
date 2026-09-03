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
    private let inbox: AsyncStream<Inbound>
    private let inboxContinuation: AsyncStream<Inbound>.Continuation
    private var started = false

    init(transport: any RuntimeTransport = XPCRuntimeTransport()) {
        self.transport = transport
        (inbox, inboxContinuation) = AsyncStream.makeStream(of: Inbound.self, bufferingPolicy: .unbounded)
    }

    /// Requests are enqueued on the same ordered inbox as every callback, synchronously, so
    /// two back-to-back sends reach the transport in the order they were made. When the
    /// consumer stops reading an accepted operation, the client unregisters it and asks the
    /// runtime to cancel it, so a host mutation never keeps running unobserved.
    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        AsyncThrowingStream { continuation in
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
            continuation.finish(throwing: RuntimeConnectionInterrupted())
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
        Task { await self.drain() }
    }

    private func drain() async {
        for await item in inbox {
            switch item {
            case .send(let request, let continuation, let key): start(request, continuation, key: key)
            case .reply(let result, let continuation, let key): handleReply(result, for: continuation, key: key)
            case .incoming(let event): route(event)
            case .interrupted: connectionDropped()
            case .consumerGone(let continuation): consumerGone(continuation)
            }
        }
    }

    private func handleReply(_ result: Result<RuntimeEvent, any Error>, for continuation: Continuation, key: ObjectIdentifier) {
        switch result {
        case .success(let event):
            continuation.yield(event)
            switch event {
            case .accepted(let id):
                // More events follow through the incoming handler until completed or failed.
                operations[id] = continuation
                consumers[key] = id
                for buffered in pendingEvents.removeValue(forKey: id) ?? [] {
                    route(buffered)
                }
            case .runtimeVersion, .status, .completed, .failed, .progress, .log:
                continuation.finish()
            }
        case .failure:
            continuation.finish(throwing: RuntimeConnectionInterrupted())
        }
    }

    private func route(_ event: RuntimeEvent) {
        switch event {
        case .progress(let id, _), .log(let id?, _):
            if let continuation = operations[id] {
                continuation.yield(event)
            } else {
                pendingEvents[id, default: []].append(event)
            }
        case .completed(let id), .failed(let id, _):
            if let continuation = operations.removeValue(forKey: id) {
                consumers = consumers.filter { $0.value != id }
                continuation.yield(event)
                continuation.finish()
            } else {
                pendingEvents[id, default: []].append(event)
            }
        case .status, .runtimeVersion, .accepted, .log(nil, _):
            for continuation in operations.values { continuation.yield(event) }
        }
    }

    private func consumerGone(_ key: ObjectIdentifier) {
        guard let id = consumers.removeValue(forKey: key), operations.removeValue(forKey: id) != nil else { return }
        pendingEvents.removeValue(forKey: id)
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
