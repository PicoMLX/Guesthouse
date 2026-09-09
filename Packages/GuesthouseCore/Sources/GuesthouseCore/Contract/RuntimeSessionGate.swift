import Synchronization

/// Serializes one session's reply accounting, refusal, and synchronous operation registration.
/// This is not an executor or command interface. Only authenticated, admitted, validated
/// requests may reach commit. Registration is bounded, synchronous and in-memory: no I/O,
/// suspension or reentry. Register identity/cancellation here; perform work outside the gate.
/// Mutex fits the native synchronous callback boundary without unchecked Sendable or actors.
public final class RuntimeSessionGate: Sendable {
    // Internal so tests can nonblockingly verify registration shares the refusal lock.
    let state = Mutex(RuntimeDispatcher.SessionLifetime())

    public init() {}

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
        try state.withLock { lifetime in
            if let refusal = lifetime.refusal { return refusal }
            return try register(request)
        }
    }

    /// After reply handoff, returns whether this caller owns the refused session's cancel.
    public func finished() -> Bool { state.withLock { $0.finished() } }
}
