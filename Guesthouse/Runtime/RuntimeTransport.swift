import Foundation
import GuesthouseCore
import Synchronization
import XPC

/// The thin seam between `RuntimeClient` and XPC, so the client's decoding and interruption
/// handling can be tested without a live service.
nonisolated protocol RuntimeTransport: Sendable {
    /// Sends one envelope and delivers exactly one reply or an error.
    func send(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws
    /// Pushed events (progress, log, status) arrive through `incoming`; `interrupted` is called
    /// when the connection drops or when a pushed message cannot be decoded, which means the
    /// peer's response cannot be trusted and every in-flight outcome is unknown. The optional
    /// failure preserves contract diagnostics; nil denotes an ordinary connection loss.
    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable (RuntimeSessionFailure?) -> Void)
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
        try send(envelope) { (result: Result<RuntimeEventEnvelope, any Error>) in
            reply(result.map(\.event))
        }
    }
}

/// Identity and retirement cause for one connection. The registry publishes retirement
/// under its lock; callbacks retain only their own generation, not an unbounded history.
nonisolated final class SessionGeneration: Sendable {
    private let storage = Mutex<RuntimeSessionFailure?>(nil)
    fileprivate var failure: RuntimeSessionFailure? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// Which session the transport is talking to and what its callbacks may reach. Sessions are
/// identified by tokens, so a retired session's callback never touches its replacement.
/// Generic over the session type, so those rules can be tested without a live XPC connection.
nonisolated final class SessionRegistry<Session>: @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?
    private var generation = SessionGeneration()
    private var incoming: (@Sendable (RuntimeEvent) -> Void)?
    private var interrupted: (@Sendable (RuntimeSessionFailure?) -> Void)?

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable (RuntimeSessionFailure?) -> Void) {
        lock.withLock {
            self.incoming = incoming
            self.interrupted = interrupted
        }
    }

    /// The live session and its generation, creating one with `make` when there is none.
    /// `make` is given the generation, because a session's callbacks are written before the
    /// session exists and each one has to name the session it belongs to.
    func session(_ make: (SessionGeneration) throws -> Session) rethrows -> (session: Session, generation: SessionGeneration) {
        try lock.withLock {
            if let session { return (session, generation) }
            generation = SessionGeneration()
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
        from generation: SessionGeneration,
        to reply: @Sendable (Result<RuntimeEvent, any Error>) -> Void
    ) {
        lock.withLock {
            // A contract failure also belongs to unanswered requests on the retired session.
            // Retaining it on that generation avoids both erasing it and blaming a new peer.
            if self.generation !== generation, generation.failure == nil,
               case .failure(let error) = result, let failure = RuntimeSessionFailure(decoding: error) {
                // Ordinary cancellation may have won the race with this reply's decoder.
                // Preserve its known cause for this request only, never the replacement.
                reply(.failure(failure))
                return
            }
            reply(self.generation === generation ? result : .failure((generation.failure as (any Error)?) ?? RuntimeConnectionInterrupted()))
        }
    }

    /// Delivers a pushed event, but only while its session is live. The handler runs under the
    /// lock, so the check and the delivery are one step: a retirement racing this call either
    /// happens entirely before it, and the event is dropped, or entirely after the event is
    /// queued behind the operations it belongs to. The handler only enqueues on the client's
    /// unbounded inbox, so nothing waits while the lock is held.
    func deliverIncoming(_ event: RuntimeEvent, from generation: SessionGeneration) {
        lock.withLock {
            guard self.generation === generation else { return }
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
    func retire(_ generation: SessionGeneration, failure: RuntimeSessionFailure? = nil) -> Session? {
        lock.withLock {
            guard self.generation === generation else { return nil }
            generation.failure = failure
            self.generation = SessionGeneration()
            let doomed = session
            session = nil
            interrupted?(failure)
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
        _ dropped: @escaping @Sendable (String?, RuntimeSessionFailure?) -> Void
    ) throws -> any RuntimeSessionHandle

    private let registry = SessionRegistry<any RuntimeSessionHandle>()
    private let connect: Connect

    init(connect: @escaping Connect = XPCRuntimeTransport.connectToService) {
        self.connect = connect
    }

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable (RuntimeSessionFailure?) -> Void) {
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
                if case .failure(let error) = result {
                    self.dropSession(generation: generation, reason: "reply failed", failure: RuntimeSessionFailure(decoding: error))
                }
                self.registry.deliverReply(result, from: generation, to: reply)
            }
        } catch {
            // The session refused the send, so it is unusable: it is retired here instead of
            // waiting for its cancellation handler, so the next request performs the
            // documented lazy reconnect rather than being handed the same dead session.
            // Retirement reports the interruption once, so a handler that follows adds nothing.
            dropSession(generation: generation, reason: "send failed", failure: RuntimeSessionFailure(decoding: error))
            throw error
        }
    }

    private func activeSession() throws -> (session: any RuntimeSessionHandle, generation: SessionGeneration) {
        try registry.session { generation in
            try connect(
                { [weak self] event in self?.registry.deliverIncoming(event, from: generation) },
                { [weak self] reason, failure in self?.dropSession(generation: generation, reason: reason, failure: failure) }
            )
        }
    }

    /// The real connection to the embedded service.
    static func connectToService(
        incoming: @escaping @Sendable (RuntimeEvent) -> Void,
        dropped: @escaping @Sendable (String?, RuntimeSessionFailure?) -> Void
    ) throws -> any RuntimeSessionHandle {
        // Created inactive: the session is activated once below. Creating it active and
        // activating again is an XPC API misuse that traps on first use.
        let created = try XPCSession(
            xpcService: serviceName,
            options: .inactive,
            incomingMessageHandler: { (message: XPCReceivedMessage) -> (any Encodable)? in
                handleIncoming(message, incoming: incoming, dropped: dropped)
                return nil
            },
            cancellationHandler: { _ in dropped(nil, nil) }
        )
        try created.activate()
        return created
    }

    /// Native Codable boundary shared by the live connection and anonymous-XPC tests.
    static func handleIncoming(
        _ message: XPCReceivedMessage,
        incoming: @escaping @Sendable (RuntimeEvent) -> Void,
        dropped: @escaping @Sendable (String?, RuntimeSessionFailure?) -> Void
    ) {
        do {
            incoming(try message.decode(as: RuntimeEventEnvelope.self).event)
        } catch {
            // Do not log decoder text: it can quote an untrusted payload.
            dropped("undecodable event", RuntimeSessionFailure(decoding: error) ?? RuntimeSessionFailure(cause: .malformedResponse))
        }
    }

    /// Clears the session and reports an interruption only if the session that failed is
    /// still the current one.
    private func dropSession(generation: SessionGeneration, reason: String?, failure: RuntimeSessionFailure? = nil) {
        // The generation is retired and the interruption reported while the registry is
        // locked, so no replacement session can carry a request past that report. The
        // cancellation runs afterwards, outside the lock, because it calls this method back.
        let doomed = registry.retire(generation, failure: failure)
        if let doomed, let reason { doomed.cancel(reason: reason) }
    }
}
