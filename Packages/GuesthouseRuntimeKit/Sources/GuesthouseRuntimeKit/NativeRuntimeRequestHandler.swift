import Foundation
import GuesthouseCore
import XPC

/// Native service ingress for #19/#20/#112 (MVP-PLAN.md §3). No listener is activated here.
/// Only runtimeVersion is implemented: mutations stay unavailable until streaming and
/// operation correlation/unknown-outcome handling migrate across all native consumers.
public final class NativeRuntimeRequestHandler: XPCPeerHandler, Sendable {
    // In-process service policy only. Neither closures nor worker tickets cross XPC.
    enum ReplyPlan: Sendable {
        case immediate(RuntimeEvent)
        case readOnly(@Sendable () -> RuntimeEvent)
    }
    private enum Delivery: Sendable {
        case immediate(RuntimeEvent)
        case deferred(RuntimeReadOnlyWorker.Ticket)
    }
    private let gate: RuntimeSessionGate
    private let worker: RuntimeReadOnlyWorker
    private let authenticate: @Sendable (XPCDictionary) -> Bool
    private let decode: @Sendable (Data, Int) -> RuntimeDispatcher.Decision
    private let plan: @Sendable (RuntimeRequest) -> ReplyPlan
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
    convenience init(
        gate: RuntimeSessionGate = RuntimeSessionGate(),
        authenticate: @escaping @Sendable (XPCDictionary) -> Bool,
        decode: @escaping @Sendable (Data, Int) -> RuntimeDispatcher.Decision = RuntimeDispatcher.decide,
        register: @escaping @Sendable (RuntimeRequest) -> RuntimeEvent,
        send: @escaping @Sendable (XPCDictionary) throws -> Void,
        cancel: @escaping @Sendable () -> Void,
        diagnostic: @escaping @Sendable (DiagnosticEvent) -> Void
    ) {
        self.init(gate: gate, worker: .shared, authenticate: authenticate, decode: decode,
                  plan: { .immediate(register($0)) }, send: send, cancel: cancel, diagnostic: diagnostic)
    }

    // Only named read-only service policy may select deferred work. Construct the worker
    // and probe owners outside the gate. This seam does not activate a new public operation.
    init(
        gate: RuntimeSessionGate, worker: RuntimeReadOnlyWorker,
        authenticate: @escaping @Sendable (XPCDictionary) -> Bool,
        decode: @escaping @Sendable (Data, Int) -> RuntimeDispatcher.Decision = RuntimeDispatcher.decide,
        plan: @escaping @Sendable (RuntimeRequest) -> ReplyPlan,
        send: @escaping @Sendable (XPCDictionary) throws -> Void,
        cancel: @escaping @Sendable () -> Void,
        diagnostic: @escaping @Sendable (DiagnosticEvent) -> Void
    ) {
        self.gate = gate; self.authenticate = authenticate; self.decode = decode
        self.worker = worker; self.plan = plan; self.send = send; self.cancel = cancel; self.diagnostic = diagnostic
    }

    public func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        guard let others = gate.began() else { return nil }
        let authorized = authenticate(message) // ORIGINAL, before context/header/payload access.
        let context = RawRuntimeReplyContext(receivedMessage: message)
        let reply = RuntimeReplyObligation(
            gate: gate, answer: { [self] event in answer(event, context: context) }, cancel: cancel
        )
        guard authorized else {
            reply.finish(refusing(.unauthorizedCaller))
            return nil
        }
        // One-way messages never decode/register: no acceptance could be observed or canceled.
        guard context != nil else {
            reply.finish(.failed(OperationID(), .invalidRequest(.malformed)))
            return nil
        }
        if let refusal = gate.refusal { reply.finish(refusal); return nil }
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
        switch decision {
        case .reply(let event): reply.finish(event)
        case .replyAndClose(let refusal):
            worker.refuse(gate, with: refusal)
            reply.finish(gate.refusal ?? refusal)
        case .dispatch(let request): dispatch(request, reply: reply)
        }
        return nil // No implicit second reply/context creation.
    }

    private func dispatch(_ request: RuntimeRequest, reply: RuntimeReplyObligation) {
        // A rejected reservation may release its Job inside the gate. Retain the plan's
        // captured owners until AFTER unlocking, including when the worker is full.
        var retainedPlan: ReplyPlan?
        defer { withExtendedLifetime(retainedPlan) {} }
        let registration = gate.commitRegistration(request) { request -> Delivery in
            let selected = plan(request)
            retainedPlan = selected
            switch selected {
            case .immediate(let event): return .immediate(event)
            case .readOnly(let work):
                guard let ticket = worker.reserve(gate: gate, reply: reply, work: work) else {
                    return .immediate(.failed(OperationID(), .invalidRequest(.tooManyInFlight)))
                }
                return .deferred(ticket)
            }
        }
        switch registration {
        case .refused(let event), .registered(.immediate(let event)): reply.finish(event)
        case .registered(.deferred(let ticket)):
            // Start even after an intervening refusal so the canceled reservation drains.
            // The production executor enqueues, never runs a probe in this native callback.
            worker.start(ticket)
        }
    }

    private func refusing(_ error: GuesthouseError) -> RuntimeEvent {
        let refusal = RuntimeEvent.failed(OperationID(), error)
        worker.refuse(gate, with: refusal)
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
        // queued reads settle without probing; already-started OS calls retain their bounded
        // capacity until return, but cannot send a second answer. No mutation is retried.
        _ = refusing(.invalidRuntimeReply(.malformed))
    }
}
