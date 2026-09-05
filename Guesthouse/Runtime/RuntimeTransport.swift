import Foundation
import GuesthouseCore
import XPC

/// The thin seam between `RuntimeClient` and XPC, so the client's decoding and interruption
/// handling can be tested without a live service.
nonisolated protocol RuntimeTransport: Sendable {
    /// Sends one envelope and delivers exactly one reply or an error.
    func send(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws
    /// Pushed events (progress, log, status) arrive through `incoming`; `interrupted` is called
    /// when the connection drops or when a pushed message cannot be decoded, which means the
    /// peer speaks a different contract and every in-flight outcome is unknown.
    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable () -> Void)
}

/// What the transport needs of one connection to the service, so the rules around it — lazy
/// reconnect, gated replies, retiring a session that refuses work — can be exercised without a
/// live XPC connection.
nonisolated protocol RuntimeSessionHandle: AnyObject, Sendable {
    func sendEnvelope(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws
    func cancel(reason: String)
}

nonisolated extension XPCSession: RuntimeSessionHandle {
    func sendEnvelope(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws {
        try send(envelope, replyHandler: reply)
    }
}

/// Which session the transport is talking to and what its callbacks may reach. Sessions are
/// numbered, so a callback of a session that has been retired never touches its replacement.
/// Generic over the session type, so those rules can be tested without a live XPC connection.
nonisolated final class SessionRegistry<Session>: @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?
    private var generation = 0
    private var incoming: (@Sendable (RuntimeEvent) -> Void)?
    private var interrupted: (@Sendable () -> Void)?

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.incoming = incoming
            self.interrupted = interrupted
        }
    }

    /// The live session and its generation, creating one with `make` when there is none.
    /// `make` is given the generation, because a session's callbacks are written before the
    /// session exists and each one has to name the session it belongs to.
    func session(_ make: (Int) throws -> Session) rethrows -> (session: Session, generation: Int) {
        try lock.withLock {
            if let session { return (session, generation) }
            generation += 1
            let created = try make(generation)
            session = created
            return (created, generation)
        }
    }

    /// Delivers the result of a send, or an interruption when the session that carried it has
    /// been retired. A late `accepted` from a dead session would otherwise register an
    /// operation nothing can ever end, so the outcome is reported as unknown instead.
    ///
    /// The check and the delivery are one step under the lock, exactly as a pushed event is.
    /// A retirement racing this call therefore happens either entirely before it, and the
    /// reply is reported as an interruption, or entirely after it, so the interruption can
    /// never be queued ahead of a reply that was gated as live. `reply` only enqueues on the
    /// client's unbounded inbox, so nothing waits while the lock is held.
    func deliverReply(
        _ result: Result<RuntimeEvent, any Error>,
        from generation: Int,
        to reply: @Sendable (Result<RuntimeEvent, any Error>) -> Void
    ) {
        lock.withLock {
            reply(self.generation == generation ? result : .failure(RuntimeConnectionInterrupted()))
        }
    }

    /// Delivers a pushed event, but only while its session is live. The handler runs under the
    /// lock, so the check and the delivery are one step: a retirement racing this call either
    /// happens entirely before it, and the event is dropped, or entirely after the event is
    /// queued behind the operations it belongs to. The handler only enqueues on the client's
    /// unbounded inbox, so nothing waits while the lock is held.
    func deliverIncoming(_ event: RuntimeEvent, from generation: Int) {
        lock.withLock {
            guard self.generation == generation else { return }
            incoming?(event)
        }
    }

    /// Retires `generation` and reports the interruption before the lock is released, handing
    /// back the session to cancel.
    ///
    /// The report happens under the lock because a replacement session can only be made by
    /// taking that same lock: the interruption is therefore always enqueued ahead of anything
    /// the replacement carries, and can never fail an operation that belongs to it. Nothing
    /// is reported and no session is returned when that generation was already retired, so a
    /// failure and the cancellation that follows it are reported once.
    func retire(_ generation: Int) -> Session? {
        lock.withLock {
            guard self.generation == generation else { return nil }
            self.generation += 1
            let doomed = session
            session = nil
            interrupted?()
            return doomed
        }
    }
}

/// The real transport over the embedded service.
nonisolated final class XPCRuntimeTransport: RuntimeTransport, @unchecked Sendable {
    static let serviceName = "com.starlingprotocol.Guesthouse.Runtime"

    /// Opens one connection to the service. `incoming` takes a pushed event; `dropped` reports
    /// that this connection is gone, carrying the reason to cancel it for, or `nil` when it has
    /// already been cancelled. Injected so the transport's rules can be tested without XPC.
    typealias Connect = @Sendable (
        _ incoming: @escaping @Sendable (RuntimeEvent) -> Void,
        _ dropped: @escaping @Sendable (String?) -> Void
    ) throws -> any RuntimeSessionHandle

    private let registry = SessionRegistry<any RuntimeSessionHandle>()
    private let connect: Connect

    init(connect: @escaping Connect = XPCRuntimeTransport.connectToService) {
        self.connect = connect
    }

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable () -> Void) {
        registry.setHandlers(incoming: incoming, interrupted: interrupted)
    }

    func send(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws {
        let (session, generation) = try activeSession()
        do {
            try session.sendEnvelope(envelope) { [weak self] (result: Result<RuntimeEvent, any Error>) in
                // A completed send races its own session's cancellation, so the reply is gated
                // on the generation it was sent from, exactly as a pushed event is.
                guard let self else {
                    reply(.failure(RuntimeConnectionInterrupted()))
                    return
                }
                // A failed reply is the session saying it produced no answer: the connection
                // was interrupted, or the peer sent something this contract cannot decode. The
                // session is retired here rather than left to a cancellation handler, which a
                // decoding failure never triggers, so the next request reconnects instead of
                // being handed the same dead session. Retiring first also orders the
                // interruption ahead of this reply, so the operations that shared the session
                // are told their outcome is unknown before it is delivered.
                if case .failure = result { self.dropSession(generation: generation, reason: "reply failed") }
                self.registry.deliverReply(result, from: generation, to: reply)
            }
        } catch {
            // The session refused the send, so it is unusable: it is retired here instead of
            // waiting for its cancellation handler, so the next request performs the
            // documented lazy reconnect rather than being handed the same dead session.
            // Retirement reports the interruption once, so a handler that follows adds nothing.
            dropSession(generation: generation, reason: "send failed")
            throw error
        }
    }

    private func activeSession() throws -> (session: any RuntimeSessionHandle, generation: Int) {
        try registry.session { generation in
            try connect(
                { [weak self] event in self?.registry.deliverIncoming(event, from: generation) },
                { [weak self] reason in self?.dropSession(generation: generation, reason: reason) }
            )
        }
    }

    /// The real connection to the embedded service.
    static func connectToService(
        incoming: @escaping @Sendable (RuntimeEvent) -> Void,
        dropped: @escaping @Sendable (String?) -> Void
    ) throws -> any RuntimeSessionHandle {
        // Created inactive: the session is activated once below. Creating it active and
        // activating again is an XPC API misuse that traps on first use.
        let created = try XPCSession(
            xpcService: serviceName,
            options: .inactive,
            incomingMessageHandler: { (message: XPCReceivedMessage) -> (any Encodable)? in
                if let event = try? message.decode(as: RuntimeEvent.self) {
                    incoming(event)
                } else {
                    // An undecodable push means a contract mismatch: treat it as a lost
                    // connection so waiting operations report an unknown outcome.
                    dropped("undecodable event")
                }
                return nil
            },
            cancellationHandler: { _ in dropped(nil) }
        )
        try created.activate()
        return created
    }

    /// Clears the session and reports an interruption only if the session that failed is
    /// still the current one.
    private func dropSession(generation: Int, reason: String?) {
        // The generation is retired and the interruption reported while the registry is
        // locked, so no replacement session can carry a request past that report. The
        // cancellation runs afterwards, outside the lock, because it calls this method back.
        let doomed = registry.retire(generation)
        if let doomed, let reason { doomed.cancel(reason: reason) }
    }
}
