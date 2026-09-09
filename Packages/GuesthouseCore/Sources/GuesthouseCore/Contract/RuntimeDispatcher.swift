import Foundation

/// Shared #20 admission decisions (MVP-PLAN.md §3), not an authenticated transport.
/// A dispatch decision still needs atomic session registration and operation-specific authority.
public enum RuntimeDispatcher: Sendable {
    public enum Decision: Hashable, Sendable {
        case reply(RuntimeEvent)
        /// Record refusal, hand over every owed reply, then close through SessionLifetime.
        case replyAndClose(RuntimeEvent)
        case dispatch(RuntimeRequest)
    }

    /// Reply obligations, not running operations. The transport balances every successful
    /// began() with exactly one finished(), AFTER handing its reply (if any) to XPC.
    public struct SessionLifetime: Sendable {
        public private(set) var inFlight = 0
        public private(set) var refusal: RuntimeEvent?
        public private(set) var isClosing = false

        public init() {}

        /// Returns the number of other replies owed. Refusal immediately stops new admission;
        /// only messages already counted may drain, so continued traffic cannot delay closure.
        public mutating func began() -> Int? {
            guard refusal == nil, !isClosing else { return nil }
            inFlight += 1
            return inFlight - 1
        }

        /// The first refusal remains authoritative; later failures cannot rewrite its cause.
        public mutating func refuse(_ rejection: RuntimeEvent) {
            if refusal == nil { refusal = rejection }
        }

        /// The caller getting true owns cancellation. Never call for an uncounted message.
        public mutating func finished() -> Bool {
            precondition(inFlight > 0, "Unbalanced runtime reply accounting")
            inFlight -= 1
            guard refusal != nil, inFlight == 0, !isClosing else { return false }
            isClosing = true
            return true
        }
    }

    public static let maximumInFlightRequestsPerSession = 8

    public static func undecodable() -> Decision {
        .reply(.failed(OperationID(), .invalidRequest(.malformed)))
    }

    /// Only reads the bounded header at the cap, never the request payload. The eventual
    /// native frame must independently enforce actual key/type/byte bounds before copying.
    public static func admit(inFlight: Int, clientVersion: () -> RuntimeProtocolVersion?) -> Decision? {
        guard inFlight >= 0 else { return undecodable() }
        guard inFlight >= maximumInFlightRequestsPerSession else { return nil }
        guard let version = clientVersion() else { return undecodable() }
        guard version == .current else {
            return mismatch(.protocolMismatch(client: version.rawValue, service: RuntimeProtocolVersion.current.rawValue))
        }
        return .reply(.failed(OperationID(), .invalidRequest(.tooManyInFlight)))
    }

    public static func mismatch(_ error: GuesthouseError) -> Decision {
        .replyAndClose(.failed(OperationID(), error))
    }

    public static func refused(_ rejection: RuntimeEvent) -> Decision { .reply(rejection) }

    /// Pure early-rejection convenience, NOT authorization based on a refusal snapshot.
    /// RuntimeSessionGate.commit must recheck refusal and register under the same lock.
    public static func honoring(_ refusal: RuntimeEvent?, _ decision: Decision) -> Decision {
        guard let refusal, case .dispatch = decision else { return decision }
        return refused(refusal)
    }

    /// Accept only the original JSON payload bytes. Measuring a decoded/re-encoded envelope
    /// loses ignored fields (#112); there is deliberately no decoded-envelope overload.
    /// The size check bounds JSON work here, not native XPC's receive/copy allocation.
    public static func decide(_ data: Data, inFlight: Int) -> Decision {
        do {
            try RequestValidator.validateEncodedSize(data)
            if let refusal = admit(inFlight: inFlight, clientVersion: {
                try? JSONDecoder().decode(Header.self, from: data).protocolVersion
            }) { return refusal }
            return .dispatch(try RequestValidator.decode(data).request)
        } catch {
            let event = RuntimeEvent.failed(OperationID(), error.guesthouseError)
            if case .protocolMismatch = error { return .replyAndClose(event) }
            return .reply(event)
        }
    }

    private struct Header: Decodable {
        let protocolVersion: RuntimeProtocolVersion
    }
}
