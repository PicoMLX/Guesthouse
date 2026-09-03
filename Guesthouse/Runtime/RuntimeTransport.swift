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
            let created = try XPCSession(
                xpcService: Self.serviceName,
                incomingMessageHandler: { [weak self] (message: XPCReceivedMessage) -> (any Encodable)? in
                    guard let self else { return nil }
                    if let event = try? message.decode(as: RuntimeEvent.self) {
                        self.lock.withLock { self.incoming }?(event)
                    } else {
                        // An undecodable push means a contract mismatch: treat it as a lost
                        // connection so waiting operations report an unknown outcome.
                        let handler = self.lock.withLock { () -> (@Sendable () -> Void)? in
                            self.session?.cancel(reason: "undecodable event")
                            self.session = nil
                            return self.interrupted
                        }
                        handler?()
                    }
                    return nil
                },
                cancellationHandler: { [weak self] _ in
                    guard let self else { return }
                    let handler = self.lock.withLock { () -> (@Sendable () -> Void)? in
                        self.session = nil
                        return self.interrupted
                    }
                    handler?()
                }
            )
            try created.activate()
            session = created
            return created
        }
    }
}
