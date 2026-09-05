import Synchronization

/// Serializes one session's reply accounting, refusal, and synchronous operation registration.
///
/// This is not an executor or command interface. Only an authenticated, admitted, validated
/// request may reach `commit`. Registration must be bounded, synchronous, and in-memory: no
/// I/O, suspension, or reentry into this gate. Future asynchronous operations must register
/// their identity and cancellation ownership here, then do their work outside the gate.
public final class RuntimeSessionGate: Sendable {
    // Internal so tests can nonblockingly verify that registration shares the refusal lock.
    let state = Mutex(RuntimeDispatcher.SessionLifetime())

    public init() {}

    /// Counts an incoming message, unless another caller has already taken the close.
    public func began() -> Int? { state.withLock { $0.began() } }

    /// A snapshot for early rejection only; it never authorizes dispatch.
    public var refusal: RuntimeEvent? { state.withLock { $0.refusal } }

    public func refuse(_ event: RuntimeEvent) { state.withLock { $0.refuse(event) } }

    /// Checks refusal and registers the request in the same critical section.
    ///
    /// A refusal ordered before this call prevents registration. A later refusal cannot undo
    /// an already registered operation. Neither refusal nor a thrown registration releases
    /// this message's reply obligation: its caller must still call `finished` exactly once,
    /// after handing its answer to the transport, including a failure answer after a throw.
    public func commit(
        _ request: RuntimeRequest,
        register: (RuntimeRequest) throws -> RuntimeEvent
    ) rethrows -> RuntimeEvent {
        try state.withLock { lifetime in
            if let refusal = lifetime.refusal { return refusal }
            return try register(request)
        }
    }

    /// Called once per admitted message, after its reply (if any) has been handed over.
    /// Returns whether this caller owns cancellation of the now-quiet refused session.
    public func finished() -> Bool { state.withLock { $0.finished() } }
}
