import GuesthouseCore
import Synchronization

/// Bounded consumer delivery migrated from #67/#103 RuntimeClient (MVP-PLAN.md §3).
/// No native calls, request dispatch, or pre-acceptance routing. The client owns those.
/// One consumer only. End callbacks must enqueue bounded work, never reenter a transport.
final class RuntimeEventStream: Sendable {
    enum Termination: Equatable, Sendable { case finished, abandoned }
    private enum End: Sendable { case finished, failed(RuntimeSessionFailure), rejected(GuesthouseError), abandoned }
    private enum Delivery: Sendable { case value(RuntimeEvent), end(End), wait }
    private struct State {
        var queue: [RuntimeEvent] = []
        var operation: OperationID?
        var receivedReply = false
        var end: End?
        var failureObserved = false
        var dropped: UInt64 = 0
        var terminated: (@Sendable (Termination) -> Void)?
    }
    private let state: Mutex<State>
    private let capacity: Int
    private let mayHaveMutated: Bool
    private let wakeups: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    /// The producer must not retain the returned stream: dropping it notifies abandonment.
    /// The unfolding stream adds no second payload buffer; reads release actual queue slots.
    /// Cancellation may throw or end iteration (SDK behavior); only a terminal event proves
    /// an operation finished. Abandonment always notifies the owner, including before a read.
    /// The SDK clears its unfolding closure on cancellation, releasing ConsumerLifetime even
    /// if it skips next() and the stream itself remains retained (covered by an SDK regression).
    static func make(capacity: Int = 64, mayHaveMutated: Bool,
                     terminated: @escaping @Sendable (Termination) -> Void)
        -> (producer: RuntimeEventStream, stream: AsyncThrowingStream<RuntimeEvent, any Error>) {
        let producer = RuntimeEventStream(capacity: capacity, mayHaveMutated: mayHaveMutated, terminated: terminated)
        let lifetime = ConsumerLifetime(producer)
        return (producer, AsyncThrowingStream(unfolding: { try await lifetime.producer.next() }))
    }

    private init(capacity: Int, mayHaveMutated: Bool, terminated: @escaping @Sendable (Termination) -> Void) {
        self.capacity = min(max(capacity, 2), 1_024)
        self.mayHaveMutated = mayHaveMutated
        state = Mutex(State(terminated: terminated))
        (wakeups, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    var bufferedCount: Int { state.withLock { $0.queue.count } }
    var droppedCount: UInt64 { state.withLock { $0.dropped } }

    /// Called once with the correlated reply. Acceptance always precedes pushed events.
    /// The surrounding client validates the reply against the request's expected shape.
    func reply(_ event: RuntimeEvent) {
        let ending = state.withLock { state -> Bool in
            guard state.end == nil else { return false }
            guard !state.receivedReply else {
                state.end = .failed(failure(.malformedResponse, state: state)); return true
            }
            state.receivedReply = true
            switch event {
            case .accepted(let id): state.operation = id; state.queue.append(event); return false
            case .runtimeVersion, .hostPreflight, .status, .completed, .failed:
                state.queue.append(event); state.end = .finished; return true
            case .progress, .diagnostic:
                state.end = .failed(failure(.malformedResponse, state: state)); return true
            }
        }
        publish(ending: ending)
    }

    /// Pre-acceptance events belong in the client's separately bounded pending-event map.
    /// Wrong-operation events cannot enter this consumer, even if its caller misroutes them.
    func push(_ event: RuntimeEvent) {
        let ending = state.withLock { state -> Bool in
            guard state.end == nil, let id = state.operation else { return false }
            let terminal: Bool
            switch event {
            case .completed(let owner), .failed(let owner, _):
                guard owner == id else { return false }; terminal = true
            case .progress(let owner, _):
                guard owner == id else { return false }; terminal = false
            case .diagnostic(let diagnostic):
                guard diagnostic.operationID == id.uuid else { return false }; terminal = false
            case .status(let status):
                guard status.inFlightOperation == nil || status.inFlightOperation == id else { return false }
                terminal = false // Unscoped environment snapshots must be filtered by the client.
            case .runtimeVersion, .hostPreflight, .accepted:
                state.end = .failed(failure(.malformedResponse, state: state)); return true
            }
            // Nonterminal traffic can never consume the last terminal slot.
            if terminal {
                state.queue.append(event); state.end = .finished; return true
            }
            guard state.queue.count < capacity - 1 else {
                if state.dropped < .max { state.dropped += 1 }
                return false
            }
            state.queue.append(event); return false
        }
        publish(ending: ending)
    }

    /// A late owning reply can enrich an unread failure, never replace an observed outcome.
    /// The router must retain request context for replies arriving after failure observation.
    func interrupt(_ error: RuntimeSessionFailure) {
        let ending = state.withLock { state -> Bool in
            if case .failed(let existing) = state.end, !state.failureObserved {
                guard existing.operationID == nil || error.operationID == nil
                    || existing.operationID == error.operationID else { return false }
                // Match registry semantics: ordinary cancellation can precede a precise cause.
                let cause = existing.cause == .connectionLost ? error.cause : existing.cause
                state.end = .failed(.init(cause: cause,
                    operationID: existing.operationID ?? error.operationID,
                    mayHaveMutated: existing.mayHaveMutated || error.mayHaveMutated))
                return false // Preserve a known ID/specific cause and the single end callback.
            }
            guard state.end == nil else { return false }
            state.end = .failed(error.contextualized(operationID: state.operation, mayHaveMutated: mayHaveMutated))
            return true
        }
        publish(ending: ending)
    }

    /// Only for a known local rejection before sending, never an uncertain native send.
    /// Once accepted, even a mistaken caller cannot replace uncertainty with an unsent error.
    func rejectBeforeSend(_ error: GuesthouseError) {
        let ending = state.withLock { state -> Bool in
            guard state.end == nil else { return false }
            state.end = state.receivedReply
                ? .failed(failure(.malformedResponse, state: state)) : .rejected(error)
            return true
        }
        publish(ending: ending)
    }

    private func failure(_ cause: RuntimeSessionFailure.Cause, state: State) -> RuntimeSessionFailure {
        .init(cause: cause, operationID: state.operation, mayHaveMutated: mayHaveMutated)
    }
    private func publish(ending: Bool) {
        // Wake/finish and the client callback are outside the state lock.
        if ending { signal.finish(); notify(.finished) }
        else { signal.yield(()) }
    }
    private func abandon() {
        let notify = state.withLock { state -> Bool in
            state.queue.removeAll()
            guard state.end == nil else { return false }
            state.end = .abandoned; return true
        }
        signal.finish()
        if notify { self.notify(.abandoned) }
    }
    private func notify(_ reason: Termination) {
        let callback = state.withLock { state in
            let callback = state.terminated
            state.terminated = nil // A finished stream must not retain its client owner.
            return callback
        }
        callback?(reason)
    }
    private func take() -> Delivery {
        state.withLock { state in
            if !state.queue.isEmpty { return .value(state.queue.removeFirst()) }
            if case .failed = state.end { state.failureObserved = true }
            return state.end.map(Delivery.end) ?? .wait
        }
    }
    private func next() async throws -> RuntimeEvent? {
        try await withTaskCancellationHandler {
            var iterator = wakeups.makeAsyncIterator()
            while true {
                if Task.isCancelled { throw GuesthouseError.canceled }
                switch take() {
                case .value(let event): return event
                case .end(.finished): return nil
                case .end(.failed(let error)): throw error
                case .end(.rejected(let error)): throw error
                case .end(.abandoned): throw GuesthouseError.canceled
                case .wait: _ = await iterator.next()
                }
            }
        } onCancel: { self.abandon() }
    }

    private final class ConsumerLifetime: Sendable {
        let producer: RuntimeEventStream
        init(_ producer: RuntimeEventStream) { self.producer = producer }
        deinit { producer.abandon() }
    }
}
