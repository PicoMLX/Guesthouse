import GuesthouseCore
import Synchronization
import Testing
import XPC
@testable import GuesthouseRuntimeKit

private struct RuntimeResponderTestRequest: Codable {
    let value: Int
}

@Suite(.serialized) struct RuntimeSessionResponderTests {
    @Test func terminalReplyIsDeliveredBeforeTheSessionCloses() throws {
        let serverSession = Mutex<XPCSession?>(nil)
        let lifetime = Mutex(RuntimeDispatcher.SessionLifetime())
        let expected = GuesthouseError.protocolMismatch(client: 1, service: 2)
        let listener = XPCListener(options: .inactive) { request in
            let accepted: (XPCListener.IncomingSessionRequest.Decision, XPCSession) = request.accept {
                (message: XPCReceivedMessage) -> (any Encodable)? in
                guard let session = serverSession.withLock({ $0 }) else { return nil }
                guard lifetime.withLock({ $0.began() }) != nil else { return nil }
                let event = RuntimeEvent.failed(OperationID(), expected)
                lifetime.withLock { $0.refuse(event) }
                if message.expectsReply { message.reply(event) }
                if lifetime.withLock({ $0.finished() }) {
                    session.cancel(reason: "session refused")
                }
                return nil
            }
            serverSession.withLock { $0 = accepted.1 }
            return accepted.0
        }
        try listener.activate()
        defer { listener.cancel() }

        let client = try XPCSession(endpoint: listener.endpoint)
        defer { client.cancel(reason: "test complete") }
        let reply: RuntimeEvent = try client.sendSync(RuntimeResponderTestRequest(value: 1))
        guard case .failed(_, let error) = reply else {
            Issue.record("expected a terminal failure reply")
            return
        }
        #expect(error == expected)
        #expect(lifetime.withLock { $0.isClosing })
    }
}
