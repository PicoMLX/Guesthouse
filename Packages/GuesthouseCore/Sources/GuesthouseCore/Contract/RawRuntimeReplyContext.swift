import Foundation
import Synchronization
import XPC

/// Owns the single native reply context of one received dictionary (#112 / MVP-PLAN.md §3).
/// This is framing/ownership only: no session, process, authentication policy or send API.
public final class RawRuntimeReplyContext: Sendable {
    private let pending: Mutex<NativeReply?>

    // The C factory is XPC_MALLOC: this is a NEW retained dictionary, never the received
    // message or an externally supplied dictionary. Swift cannot infer that independence.
    // The wrapper is private, created only below, and accessed only while claiming pending
    // under its mutex. Clearing pending transfers the only reachable dictionary to the winner.
    // Remove this FFI bridge when the importer models independent native-result ownership.
    private struct NativeReply: @unchecked Sendable {
        let dictionary: XPCDictionary
    }

    /// The transport must authenticate the ORIGINAL message before calling this initializer.
    /// Call once per received message. Nil means no available native reply context (including
    /// one-way messages), not authentication or permission to dispatch. Successful creation
    /// consumes XPC's context; the handler must return nil, never request an implicit reply.
    /// Do not concurrently access the original dictionary while consuming its reply context.
    public init?(receivedMessage: XPCDictionary) {
        guard let reply = receivedMessage.withUnsafeUnderlyingDictionary({ xpc_dictionary_create_reply($0) }) else {
            return nil
        }
        pending = Mutex(NativeReply(dictionary: XPCDictionary(reply)))
    }

    /// Transfers a bounded framed reply to at most one caller, even under concurrent attempts.
    /// Invalid bytes do not consume the retained reply, so a typed encoding failure can still
    /// be answered. Nil means another caller already claimed it; do not send or finish twice.
    /// The winner must explicitly send through its active XPCSession before finishing the
    /// counted callback or canceling the session. A send error never authorizes reclaim/retry.
    /// Handoff to XPC is not proof of delivery or of a mutating operation's outcome.
    public func takeReply(
        payload: Data, protocolVersion: Int64
    ) throws(RawRuntimeFrame.Failure) -> XPCDictionary? {
        guard payload.count <= RawRuntimeFrame.maximumPayloadBytes else { throw .oversized }
        guard !payload.isEmpty else { throw .malformed }
        return pending.withLock { pending in
            guard let native = pending else { return nil }
            pending = nil
            var reply = native.dictionary
            reply["protocolVersion"] = protocolVersion
            reply["payload"] = payload.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
            return reply
        }
    }
}
