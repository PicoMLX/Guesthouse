import Foundation

/// The service-side decision for one received message, before any operation runs.
///
/// Pure, so the handshake and validation rules are unit-tested here rather than inside the
/// XPC service bundle. The service applies the decision: it replies, and for `replyAndClose`
/// it marks the session refused and closes it on the first later message that finds the
/// session quiet, so the reply is always delivered first (MVP-PLAN.md §3, "Sandbox and XPC
/// boundary").
public enum RuntimeDispatcher: Sendable {
    public enum Decision: Hashable, Sendable {
        /// Reply with this event and keep the session.
        case reply(RuntimeEvent)
        /// Reply with this event, then close the session. Used for protocol mismatches, where
        /// the peer is a different build of Guesthouse and nothing it sends can be trusted.
        case replyAndClose(RuntimeEvent)
        /// Close the session without replying: it has already been answered with a rejection
        /// and nothing is outstanding on it.
        case close
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

    /// Decides what to do before the request payload is decoded: the concurrency cap costs
    /// nothing to apply, so it is applied first and a peer over the cap never reaches the
    /// payload decoder.
    ///
    /// `clientVersion` is asked only once the cap is exceeded, and only for the version
    /// header, because a refusal is worth sending only if the peer can read it:
    /// `tooManyInFlight` arrived with protocol 2, so a peer speaking any other version is
    /// answered with the protocol mismatch it can act on instead of a reason its decoder
    /// would throw away.
    public static func admit(inFlight: Int, clientVersion: () -> RuntimeProtocolVersion?) -> Decision? {
        guard inFlight >= maximumInFlightRequestsPerSession else { return nil }
        // A header that will not decode says nothing about the peer's version, so it gets the
        // one rejection every version has always understood.
        guard let version = clientVersion() else { return undecodable() }
        guard version == .current else {
            return mismatch(.protocolMismatch(client: version.rawValue, service: RuntimeProtocolVersion.current.rawValue))
        }
        return .reply(.failed(OperationID(), .invalidRequest(.tooManyInFlight)))
    }

    /// Decides what to do with a message whose protocol version does not match this service.
    public static func mismatch(_ error: GuesthouseError) -> Decision {
        .replyAndClose(.failed(OperationID(), error))
    }

    /// Decides what to do with a message arriving on a session already answered with a
    /// rejection.
    ///
    /// A session handler serves pipelined requests, so a new message is no evidence that the
    /// earlier rejection reached the peer: closing while other requests are still outstanding
    /// can discard it, leaving a bare connection interruption in place of the protocol
    /// mismatch or unauthorized-caller recovery. The rejection is repeated while the session
    /// is busy, and the close waits for the first message that finds it quiet.
    public static func refused(_ rejection: RuntimeEvent, inFlight: Int) -> Decision {
        inFlight > 0 ? .reply(rejection) : .close
    }

    /// Decides what to do with a decoded envelope.
    public static func decide(_ envelope: RuntimeRequestEnvelope, inFlight: Int) -> Decision {
        // The version needs no second look here: the envelope carries the header it decoded.
        if let refused = admit(inFlight: inFlight, clientVersion: { envelope.protocolVersion }) { return refused }
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
