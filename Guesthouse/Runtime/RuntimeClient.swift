import Foundation
import GuesthouseCore

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
        case reply(Result<RuntimeEvent, any Error>, Continuation)
        case incoming(RuntimeEvent)
        case interrupted
    }

    private let transport: any RuntimeTransport
    private var operations: [OperationID: Continuation] = [:]
    /// Events that arrived for an operation before its `accepted` reply registered a consumer.
    private var pendingEvents: [OperationID: [RuntimeEvent]] = [:]
    private let inbox: AsyncStream<Inbound>
    private let inboxContinuation: AsyncStream<Inbound>.Continuation
    private var started = false

    init(transport: any RuntimeTransport = XPCRuntimeTransport()) {
        self.transport = transport
        (inbox, inboxContinuation) = AsyncStream.makeStream(of: Inbound.self, bufferingPolicy: .unbounded)
    }

    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task { await self.start(request, continuation) }
        }
    }

    private func start(_ request: RuntimeRequest, _ continuation: Continuation) {
        startIfNeeded()
        do {
            try transport.send(RuntimeRequestEnvelope(request: request)) { [inboxContinuation] result in
                inboxContinuation.yield(.reply(result, continuation))
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
            case .reply(let result, let continuation): handleReply(result, for: continuation)
            case .incoming(let event): route(event)
            case .interrupted: connectionDropped()
            }
        }
    }

    private func handleReply(_ result: Result<RuntimeEvent, any Error>, for continuation: Continuation) {
        switch result {
        case .success(let event):
            continuation.yield(event)
            switch event {
            case .accepted(let id):
                // More events follow through the incoming handler until completed or failed.
                operations[id] = continuation
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
                continuation.yield(event)
                continuation.finish()
            } else {
                pendingEvents[id, default: []].append(event)
            }
        case .status, .runtimeVersion, .accepted, .log(nil, _):
            for continuation in operations.values { continuation.yield(event) }
        }
    }

    private func connectionDropped() {
        let pending = operations
        operations.removeAll()
        pendingEvents.removeAll()
        for (id, continuation) in pending {
            continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
        }
    }
}
