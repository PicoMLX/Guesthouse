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

/// Which session the transport is talking to and what its callbacks may reach. Sessions are
/// numbered, so a callback of a session that has been retired never touches its replacement.
/// Generic over the session type, so those rules can be tested without a live XPC connection.
nonisolated final class SessionRegistry<Session: AnyObject>: @unchecked Sendable {
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

    /// Whether `generation` is still the session the client is talking to.
    func isLive(_ generation: Int) -> Bool { lock.withLock { self.generation == generation } }

    /// The result of a send, or an interruption when the session that carried it has been
    /// retired. A late `accepted` from a dead session would otherwise register an operation
    /// nothing can ever end, so the outcome is reported as unknown instead.
    func gate(_ result: Result<RuntimeEvent, any Error>, from generation: Int) -> Result<RuntimeEvent, any Error> {
        isLive(generation) ? result : .failure(RuntimeConnectionInterrupted())
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

    /// Retires `generation`, handing back the session to cancel and the handler that reports
    /// the interruption. Both are `nil` when that generation was already retired, so a failure
    /// and the cancellation that follows it are reported once.
    func retire(_ generation: Int) -> (session: Session?, interrupted: (@Sendable () -> Void)?) {
        lock.withLock {
            guard self.generation == generation else { return (nil, nil) }
            self.generation += 1
            let doomed = session
            session = nil
            return (doomed, interrupted)
        }
    }
}

/// The real transport over the embedded service.
nonisolated final class XPCRuntimeTransport: RuntimeTransport, @unchecked Sendable {
    static let serviceName = "com.starlingprotocol.Guesthouse.Runtime"

    private let registry = SessionRegistry<XPCSession>()

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable () -> Void) {
        registry.setHandlers(incoming: incoming, interrupted: interrupted)
    }

    func send(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws {
        let (session, generation) = try activeSession()
        try session.send(envelope) { [weak self] (result: Result<RuntimeEvent, any Error>) in
            // A completed send races its own session's cancellation, so the reply is gated on
            // the generation it was sent from, exactly as a pushed event is.
            guard let self else {
                reply(.failure(RuntimeConnectionInterrupted()))
                return
            }
            reply(self.registry.gate(result, from: generation))
        }
    }

    private func activeSession() throws -> (session: XPCSession, generation: Int) {
        try registry.session { generation in
            // Created inactive: the session is activated once below. Creating it active and
            // activating again is an XPC API misuse that traps on first use.
            let created = try XPCSession(
                xpcService: Self.serviceName,
                options: .inactive,
                incomingMessageHandler: { [weak self] (message: XPCReceivedMessage) -> (any Encodable)? in
                    guard let self else { return nil }
                    if let event = try? message.decode(as: RuntimeEvent.self) {
                        self.registry.deliverIncoming(event, from: generation)
                    } else {
                        // An undecodable push means a contract mismatch: treat it as a lost
                        // connection so waiting operations report an unknown outcome.
                        self.dropSession(generation: generation, reason: "undecodable event")
                    }
                    return nil
                },
                cancellationHandler: { [weak self] _ in
                    self?.dropSession(generation: generation, reason: nil)
                }
            )
            try created.activate()
            return created
        }
    }

    /// Clears the session and reports an interruption only if the session that failed is
    /// still the current one.
    private func dropSession(generation: Int, reason: String?) {
        // The generation is retired before the session is canceled, so the cancellation
        // handler that follows reports nothing a second time.
        let (doomed, handler) = registry.retire(generation)
        if let doomed, let reason { doomed.cancel(reason: reason) }
        handler?()
    }
}
