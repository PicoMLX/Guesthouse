import Foundation
import GuesthouseCore

/// The GUI's `RuntimeBackend` over XPC.
///
/// Connects lazily, maps a dropped connection to `RuntimeConnectionInterrupted` so callers
/// treat in-flight work as unknown outcome (MVP-PLAN.md §3), and reconnects on the next
/// request. Long-running operations stream their events through the transport's incoming
/// handler and are demultiplexed by `OperationID`.
actor RuntimeClient: RuntimeBackend {
    typealias Continuation = AsyncThrowingStream<RuntimeEvent, any Error>.Continuation

    private let transport: any RuntimeTransport
    private var operations: [OperationID: Continuation] = [:]
    /// Events that arrived for an operation before its `accepted` reply registered a consumer.
    /// The reply and the pushed events travel on different paths, so either can come first.
    private var pendingEvents: [OperationID: [RuntimeEvent]] = [:]
    private var handlersInstalled = false

    init(transport: any RuntimeTransport = XPCRuntimeTransport()) {
        self.transport = transport
    }

    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task { await self.start(request, continuation) }
        }
    }

    private func start(_ request: RuntimeRequest, _ continuation: Continuation) {
        installHandlersIfNeeded()
        do {
            try transport.send(RuntimeRequestEnvelope(request: request)) { result in
                Task { await self.handleReply(result, for: continuation) }
            }
        } catch {
            continuation.finish(throwing: RuntimeConnectionInterrupted())
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

    private func installHandlersIfNeeded() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        transport.setHandlers(
            incoming: { event in Task { await self.route(event) } },
            interrupted: { Task { await self.connectionDropped() } }
        )
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
        for (id, continuation) in pending {
            continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
        }
    }
}
