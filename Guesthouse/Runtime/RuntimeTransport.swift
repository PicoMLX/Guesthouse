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

/// The real transport over the embedded service.
nonisolated final class XPCRuntimeTransport: RuntimeTransport, @unchecked Sendable {
    static let serviceName = "com.starlingprotocol.Guesthouse.Runtime"

    private let lock = NSLock()
    private var session: XPCSession?
    /// Incremented per session, so a callback from a canceled session never clears its
    /// replacement or reports a second interruption for it.
    private var generation = 0
    private var incoming: (@Sendable (RuntimeEvent) -> Void)?
    private var interrupted: (@Sendable () -> Void)?

    func setHandlers(incoming: @escaping @Sendable (RuntimeEvent) -> Void, interrupted: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.incoming = incoming
            self.interrupted = interrupted
        }
    }

    func send(_ envelope: RuntimeRequestEnvelope, reply: @escaping @Sendable (Result<RuntimeEvent, any Error>) -> Void) throws {
        let session = try activeSession()
        try session.send(envelope) { (result: Result<RuntimeEvent, any Error>) in
            reply(result)
        }
    }

    private func activeSession() throws -> XPCSession {
        try lock.withLock {
            if let session { return session }
            generation += 1
            let mine = generation
            // Created inactive: the session is activated once below. Creating it active and
            // activating again is an XPC API misuse that traps on first use.
            let created = try XPCSession(
                xpcService: Self.serviceName,
                options: .inactive,
                incomingMessageHandler: { [weak self] (message: XPCReceivedMessage) -> (any Encodable)? in
                    guard let self else { return nil }
                    if let event = try? message.decode(as: RuntimeEvent.self) {
                        self.lock.withLock { self.incoming }?(event)
                    } else {
                        // An undecodable push means a contract mismatch: treat it as a lost
                        // connection so waiting operations report an unknown outcome.
                        self.dropSession(generation: mine, reason: "undecodable event")
                    }
                    return nil
                },
                cancellationHandler: { [weak self] _ in
                    self?.dropSession(generation: mine, reason: nil)
                }
            )
            try created.activate()
            session = created
            return created
        }
    }

    /// Clears the session and reports an interruption only if the session that failed is
    /// still the current one.
    private func dropSession(generation: Int, reason: String?) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            guard self.generation == generation else { return nil }
            if let reason { session?.cancel(reason: reason) }
            session = nil
            return interrupted
        }
        handler?()
    }
}
