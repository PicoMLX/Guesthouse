import Synchronization

/// Serializes one session's reply accounting, refusal, and synchronous operation registration.
/// This is not an executor or command interface. Only authenticated, admitted, validated
/// requests may reach commit. Registration is bounded, synchronous and in-memory: no I/O,
/// suspension or reentry. Register identity/cancellation here; perform work outside the gate.
/// Mutex fits the native synchronous callback boundary without unchecked Sendable or actors.
public final class RuntimeSessionGate: Sendable {
    /// In-process registration outcome, NOT a wire acknowledgement or completed operation.
    /// A deferred worker returns its ticket here without fabricating a RuntimeEvent.
    public enum Registration<Value: Sendable>: Sendable {
        case registered(Value)
        case refused(RuntimeEvent)
    }

    // Internal so tests can nonblockingly verify registration shares the refusal lock.
    let state = Mutex(RuntimeDispatcher.SessionLifetime())

    public init() {}

    /// Refusal and admission share this lock. A nil result incurs no reply obligation:
    /// the adapter must not decode, dispatch, or call finished for that later callback.
    public func began() -> Int? { state.withLock { $0.began() } }

    /// Early rejection only; a snapshot cannot authorize later dispatch.
    public var refusal: RuntimeEvent? { state.withLock { $0.refusal } }

    public func refuse(_ event: RuntimeEvent) { state.withLock { $0.refuse(event) } }

    /// A prior refusal prevents registration. A later refusal cannot undo registered work.
    /// Refusal or a thrown registration still owes this message's reply: hand over its answer,
    /// including a typed failure after a throw, then call finished exactly once.
    public func commit(
        _ request: RuntimeRequest,
        register: (RuntimeRequest) throws -> RuntimeEvent
    ) rethrows -> RuntimeEvent {
        switch try commitRegistration(request, register: register) {
        case .registered(let event), .refused(let event): return event
        }
    }

    /// The same authenticated/admitted boundary as commit, with a typed in-process value.
    /// Only register identity/ownership here; start a deferred ticket AFTER this returns,
    /// even if refusal follows registration. Refusal/throw does not settle the counted reply.
    /// Keep callback captures alive outside this gate; no I/O, reply delivery or reentrant deinit
    /// may run under its mutex (MVP-PLAN.md §3). A registered nil is distinct from refusal.
    public func commitRegistration<Value: Sendable>(
        _ request: RuntimeRequest,
        register: (RuntimeRequest) throws -> Value
    ) rethrows -> Registration<Value> {
        try state.withLock { lifetime in
            if let refusal = lifetime.refusal { return .refused(refusal) }
            return .registered(try register(request))
        }
    }

    /// After reply handoff, returns whether this caller owns the refused session's cancel.
    public func finished() -> Bool { state.withLock { $0.finished() } }
}
