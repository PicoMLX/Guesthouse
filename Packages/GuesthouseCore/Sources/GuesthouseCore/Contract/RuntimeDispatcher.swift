/// The service-side decision for one received message, before any operation runs.
///
/// Pure, so the handshake and validation rules are unit-tested here rather than inside the
/// XPC service bundle. The service applies the decision: it replies, and for
/// `replyAndClose` it also cancels the session (MVP-PLAN.md §3, "Sandbox and XPC boundary").
public enum RuntimeDispatcher {
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

    /// Decides what to do with a message that failed to decode as an envelope.
    public static func undecodable() -> Decision {
        .reply(.failed(OperationID(), .invalidRequest(.malformed)))
    }

    /// Decides what to do with a decoded envelope.
    public static func decide(_ envelope: RuntimeRequestEnvelope, inFlight: Int) -> Decision {
        do {
            try RequestValidator.validate(envelope)
        } catch {
            if case .protocolMismatch = error {
                return .replyAndClose(.failed(OperationID(), error.guesthouseError))
            }
            return .reply(.failed(OperationID(), error.guesthouseError))
        }
        guard inFlight < maximumInFlightRequestsPerSession else {
            return .reply(.failed(OperationID(), .invalidRequest(.oversized)))
        }
        return .dispatch(envelope.request)
    }
}
