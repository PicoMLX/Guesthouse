import GuesthouseCore
import XPC

/// Applies the service's terminal reply ordering. `XPCPeerHandler` normally sends a returned
/// value after the handler exits, but canceling the session before that send discards the reply.
public enum RuntimeSessionResponder {
    public enum CloseReason: Sendable {
        case protocolMismatch
        case unauthorizedCaller

        fileprivate var text: String {
            switch self {
            case .protocolMismatch: "protocol mismatch"
            case .unauthorizedCaller: "unauthorized caller"
            }
        }
    }

    /// Enqueues an expected reply before closing the session. The caller must return `nil` from
    /// its peer handler afterward so XPC does not attempt a second automatic reply.
    public static func replyAndClose(
        _ event: RuntimeEvent,
        to message: XPCReceivedMessage,
        session: XPCSession,
        reason: CloseReason
    ) {
        if message.expectsReply { message.reply(event) }
        session.cancel(reason: reason.text)
    }
}
