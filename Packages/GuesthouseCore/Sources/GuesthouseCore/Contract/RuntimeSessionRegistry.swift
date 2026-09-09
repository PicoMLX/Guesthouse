import Synchronization

/// Callbacks retain their own generation, not an ever-growing history of retired sessions.
public final class RuntimeSessionGeneration: Sendable {
    fileprivate let retirement = Mutex<RuntimeSessionFailure.Cause?>(nil)
    fileprivate init() {}
    /// Diagnostic after retirement, never a connection-authority snapshot. Setup can fail
    /// before a request exists; preserve its known contract cause without inventing an ID.
    public var retirementFailure: RuntimeSessionFailure? {
        retirement.withLock { $0.map { RuntimeSessionFailure(cause: $0) } }
    }
}

/// In-memory client session ownership and ordered delivery (#19/#112, MVP-PLAN.md §3).
/// No session creation/activation/cancellation, native I/O, tasks or operation dispatch here.
/// Delivery callbacks MUST only enqueue bounded work: no blocking, I/O or registry reentry.
/// Their synchronous handoff shares the retirement lock so an interruption cannot overtake
/// a live reply or trail the replacement's events. Cancellation always happens outside it.
public final class RuntimeSessionRegistry<Session: Sendable>: Sendable {
    public struct Lease: Sendable {
        public let session: Session
        public let generation: RuntimeSessionGeneration
    }
    struct State: Sendable {
        var generation: RuntimeSessionGeneration?
        var session: Session?
        var ready = false
    }
    // Internal for nonblocking lock-ownership tests; not an authorization snapshot.
    let state = Mutex(State())
    private let incoming: @Sendable (RuntimeEvent) -> Void
    private let interrupted: @Sendable (RuntimeSessionFailure) -> Void

    public init(incoming: @escaping @Sendable (RuntimeEvent) -> Void,
                interrupted: @escaping @Sendable (RuntimeSessionFailure) -> Void) {
        self.incoming = incoming; self.interrupted = interrupted
    }

    public var current: Lease? {
        state.withLock { state in
            guard state.ready, let session = state.session, let generation = state.generation else { return nil }
            return Lease(session: session, generation: generation)
        }
    }

    /// Reserve before creating an INACTIVE native session outside this lock. Nil means a
    /// session is already live/connecting, not permission to create a competing connection.
    /// The transport serializes its setup callers; it must not hold this delivery lock.
    public func reserve() -> RuntimeSessionGeneration? {
        state.withLock { state in
            guard state.generation == nil else { return nil }
            let generation = RuntimeSessionGeneration()
            state.generation = generation
            return generation
        }
    }

    /// Transfer cleanup ownership before activation. Call once per newly created candidate;
    /// never resubmit a handle whose ownership was already transferred. On false the creator
    /// still owns that candidate and must cancel it; on true ONLY retire's winner cancels it.
    public func install(_ session: Session, for generation: RuntimeSessionGeneration) -> Bool {
        state.withLock { state in
            guard state.generation === generation, state.session == nil else { return false }
            state.session = session
            return true
        }
    }

    /// Call after successful activation, outside this lock. A retirement during setup wins:
    /// false never restores the session and does not transfer cleanup ownership back.
    public func activated(_ generation: RuntimeSessionGeneration) -> Bool {
        state.withLock { state in
            guard state.generation === generation, state.session != nil else { return false }
            state.ready = true
            return true
        }
    }

    /// Transport failures must retire first, then deliver their request-specific reply error.
    /// Even a late acceptance retains its ID as UNKNOWN outcome, never a new live operation.
    public func deliverReply(_ result: Result<RuntimeEvent, RuntimeSessionFailure>,
                             from generation: RuntimeSessionGeneration,
                             to reply: @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void) {
        state.withLock { state in
            if state.generation === generation, state.session != nil { reply(result); return }
            let cause = generation.retirement.withLock { $0 } ?? .connectionLost
            var failure = RuntimeSessionFailure(cause: cause)
            switch result {
            case .success(.accepted(let id)): failure = failure.contextualized(operationID: id)
            case .failure(let received):
                // Ordinary cancellation may have preceded the decoder's more specific cause.
                // Preserve that cause for this reply only, never for a replacement/other request.
                failure = cause == .connectionLost ? received : failure.contextualized(
                    operationID: received.operationID, mayHaveMutated: received.mayHaveMutated)
            case .success: break
            }
            reply(.failure(failure))
        }
    }

    public func deliverIncoming(_ event: RuntimeEvent, from generation: RuntimeSessionGeneration) {
        state.withLock { state in
            guard state.generation === generation, state.session != nil else { return }
            incoming(event)
        }
    }

    /// Notify exactly once, even if failure arrives before installation. Returned session is
    /// the sole cancellation handoff; no synthetic success/terminal operation event is sent.
    public func retire(_ generation: RuntimeSessionGeneration,
                       failure: RuntimeSessionFailure = .init(cause: .connectionLost)) -> Session? {
        state.withLock { state in
            guard state.generation === generation else { return nil }
            generation.retirement.withLock { $0 = failure.cause }
            let doomed = state.session
            state = State()
            interrupted(RuntimeSessionFailure(cause: failure.cause))
            return doomed
        }
    }
}
