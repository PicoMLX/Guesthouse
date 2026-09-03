import Foundation

/// The service-side decision for one received message, before any operation runs.
///
/// Pure, so the handshake and validation rules are unit-tested here rather than inside the
/// XPC service bundle. The service applies the decision: it replies, and for
/// `replyAndClose` it also cancels the session (MVP-PLAN.md §3, "Sandbox and XPC boundary").
public enum RuntimeDispatcher: Sendable {
    public enum Decision: Hashable, Sendable {
        /// Reply with this event and keep the session.
        case reply(RuntimeEvent)
        /// Reply with this event, then close the session. Used for protocol mismatches, where
        /// the peer is a different build of Guesthouse and nothing it sends can be trusted.
        case replyAndClose(RuntimeEvent)
        /// The envelope is valid; run the request.
        case dispatch(RuntimeRequest)
    }

    /// Maximum in-flight requests per session. A well-behaved GUI issues a handful; anything
    /// beyond this is a bug or an attempt to exhaust the service.
    public static let maximumInFlightRequestsPerSession = 8

    /// Decides what to do when envelope decoding fails.
    ///
    /// The envelope decoder deliberately rejects another protocol version before decoding its
    /// version-specific payload. Preserve that typed failure so stale peers get an actionable
    /// response and the service closes the incompatible session. All other decoding failures are
    /// malformed requests and must not echo attacker-controlled decoder diagnostics.
    public static func decodingFailure(_ error: any Error) -> Decision {
        if let mismatch = error as? RuntimeRequestEnvelope.ProtocolMismatch {
            return .replyAndClose(.failed(OperationID(), mismatch.error))
        }
        return .reply(.failed(OperationID(), .invalidRequest(.malformed)))
    }

    /// Decides what to do before anything is decoded: the concurrency cap costs nothing to
    /// apply, so it is applied first, and a peer over the cap never reaches the decoder.
    public static func admit(inFlight: Int) -> Decision? {
        guard inFlight >= maximumInFlightRequestsPerSession else { return nil }
        return .reply(.failed(OperationID(), .invalidRequest(.tooManyInFlight)))
    }

    /// Decides what to do with a message whose protocol version does not match this service.
    public static func mismatch(_ error: GuesthouseError) -> Decision {
        .replyAndClose(.failed(OperationID(), error))
    }

    /// Decides what to do with a decoded envelope.
    public static func decide(_ envelope: RuntimeRequestEnvelope, inFlight: Int) -> Decision {
        if let refused = admit(inFlight: inFlight) { return refused }
        do {
            // The envelope is re-encoded and measured before anything acts on it: a payload
            // beyond the declared maximum is refused rather than dispatched.
            try RequestValidator.validateEncodedSize(RuntimeDispatcher.encoded(envelope))
            try RequestValidator.validate(envelope)
        } catch {
            if case .protocolMismatch = error {
                return .replyAndClose(.failed(OperationID(), error.guesthouseError))
            }
            return .reply(.failed(OperationID(), error.guesthouseError))
        }
        return .dispatch(envelope.request)
    }

    static func encoded(_ envelope: RuntimeRequestEnvelope) -> Data {
        (try? JSONEncoder().encode(envelope)) ?? Data()
    }
}
