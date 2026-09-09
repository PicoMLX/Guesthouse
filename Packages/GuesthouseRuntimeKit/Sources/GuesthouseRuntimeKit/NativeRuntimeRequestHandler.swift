import Foundation
import GuesthouseCore
import XPC

/// Native service ingress for #19/#20/#112 (MVP-PLAN.md §3). No listener is activated here.
/// Only runtimeVersion is implemented: mutations stay unavailable until client retirement,
/// streaming and unknown-outcome handling migrate together with the activation wire epoch.
public final class NativeRuntimeRequestHandler: XPCPeerHandler, Sendable {
    private let gate: RuntimeSessionGate
    private let authenticate: @Sendable (XPCDictionary) -> Bool
    private let decode: @Sendable (Data, Int) -> RuntimeDispatcher.Decision
    private let register: @Sendable (RuntimeRequest) -> RuntimeEvent
    private let send: @Sendable (XPCDictionary) throws -> Void
    private let cancel: @Sendable () -> Void
    private let diagnostic: @Sendable (DiagnosticEvent) -> Void
    private static var epoch: Int64 { Int64(RuntimeProtocolVersion.current.rawValue) }

    /// The listener must also apply RuntimeCallerAuthentication.listenerRequirement.
    /// Bundle inspection is done by the owner, outside registration's synchronous gate.
    public convenience init(
        session: XPCSession, version: RuntimeVersionInfo,
        diagnostic: @escaping @Sendable (DiagnosticEvent) -> Void
    ) {
        self.init(
            authenticate: RuntimeCallerAuthentication.allows,
            register: { Self.queryReply($0, version: version) },
            send: { try session.send(message: $0) },
            cancel: { session.cancel(reason: "runtime session refused") },
            diagnostic: diagnostic
        )
    }

    static func queryReply(_ request: RuntimeRequest, version: RuntimeVersionInfo) -> RuntimeEvent {
        if case .runtimeVersion = request { return .runtimeVersion(version) }
        return .failed(OperationID(), .invalidRequest(.unsupportedOperation))
    }

    // Internal test seam only. Public construction never permits replacement authentication
    // or operation dispatch. Registration must stay bounded/in-memory with no I/O or reentry.
    init(
        gate: RuntimeSessionGate = RuntimeSessionGate(),
        authenticate: @escaping @Sendable (XPCDictionary) -> Bool,
        decode: @escaping @Sendable (Data, Int) -> RuntimeDispatcher.Decision = RuntimeDispatcher.decide,
        register: @escaping @Sendable (RuntimeRequest) -> RuntimeEvent,
        send: @escaping @Sendable (XPCDictionary) throws -> Void,
        cancel: @escaping @Sendable () -> Void,
        diagnostic: @escaping @Sendable (DiagnosticEvent) -> Void
    ) {
        self.gate = gate; self.authenticate = authenticate; self.decode = decode
        self.register = register; self.send = send; self.cancel = cancel; self.diagnostic = diagnostic
    }

    public func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        guard let others = gate.began() else { return nil }
        // Finish every counted callback once, AFTER explicit reply handoff (or send failure).
        // Refusal stops new admission immediately; only already counted callbacks may drain.
        defer { if gate.finished() { cancel() } }
        let authorized = authenticate(message) // ORIGINAL, before context/header/payload access.
        let context = RawRuntimeReplyContext(receivedMessage: message)
        guard authorized else {
            answer(refusing(.unauthorizedCaller), context: context)
            return nil
        }
        // One-way messages never decode/register: no acceptance could be observed or canceled.
        guard let context else {
            record(.failed(OperationID(), .invalidRequest(.malformed)))
            return nil
        }
        if let refusal = gate.refusal { answer(refusal, context: context); return nil }
        let decision: RuntimeDispatcher.Decision
        if let capped = RuntimeDispatcher.admit(inFlight: others, clientVersion: {
            message.withUnsafeUnderlyingDictionary { dictionary in
                guard let value = xpc_dictionary_get_value(dictionary, "protocolVersion"),
                      xpc_get_type(value) == XPC_TYPE_INT64,
                      let version = Int(exactly: xpc_int64_get_value(value)) else { return nil }
                return RuntimeProtocolVersion(version)
            }
        }) { decision = capped }
        else {
            do {
                let bytes = try RawRuntimeFrame.payload(message, expectedVersion: Self.epoch)
                let decoded = decode(bytes, others)
                // The authoritative outer epoch was current: a foreign nested version is a
                // contradictory frame, not a handshake from that foreign client version.
                if case .replyAndClose(.failed(_, .protocolMismatch)) = decoded {
                    decision = .replyAndClose(.failed(OperationID(), .invalidRequest(.malformed)))
                } else { decision = decoded }
            } catch {
                switch error {
                case .protocolMismatch(let version):
                    decision = .replyAndClose(.failed(OperationID(), .protocolMismatch(
                        client: Int(version), service: RuntimeProtocolVersion.current.rawValue)))
                case .oversized: decision = .reply(.failed(OperationID(), .invalidRequest(.oversized)))
                case .malformed: decision = .reply(.failed(OperationID(), .invalidRequest(.malformed)))
                }
            }
        }
        let event: RuntimeEvent
        switch decision {
        case .reply(let reply): event = reply
        case .replyAndClose(let refusal):
            gate.refuse(refusal)
            event = gate.refusal ?? refusal
        case .dispatch(let request): event = gate.commit(request, register: register)
        }
        answer(event, context: context)
        return nil // No implicit second reply/context creation.
    }

    private func refusing(_ error: GuesthouseError) -> RuntimeEvent {
        let refusal = RuntimeEvent.failed(OperationID(), error)
        gate.refuse(refusal)
        return gate.refusal ?? refusal
    }

    private func answer(_ event: RuntimeEvent, context: RawRuntimeReplyContext?) {
        record(event)
        guard let context else { return }
        let payload: Data
        do { payload = try RuntimeEventEnvelope(event: event).encoded() }
        catch {
            // No mutation can run through the public handler. This is a transport failure,
            // not success/operation completion. A future mutating adapter must preserve its
            // registered ID and unknown outcome instead of reusing this query-only fallback.
            let failure = refusing(error)
            record(failure)
            guard let bytes = try? RuntimeEventEnvelope(event: failure).encoded() else { return }
            payload = bytes
        }
        do {
            guard let reply = try context.takeReply(payload: payload, protocolVersion: Self.epoch) else {
                record(refusing(.invalidRuntimeReply(.malformed)))
                return
            }
            try send(reply)
        } catch {
            // Context ownership is already consumed. Never reclaim/retry a failed send.
            record(refusing(.invalidRuntimeReply(.malformed)))
        }
    }

    private func record(_ event: RuntimeEvent) {
        guard case .failed(let id, let error) = event else { return }
        diagnostic(DiagnosticEvent(operation: .runtimeRequest, outcome: .init(error: error), operationID: id.uuid))
    }

    public func handleCancellation(error: XPCRichError) {
        // Opaque native error text is not a diagnostic input. Stop new registration now;
        // counted callbacks still finish themselves, without inventing operation outcomes.
        _ = refusing(.invalidRuntimeReply(.malformed))
    }
}
