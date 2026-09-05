import Foundation

/// The service-side decision for one received message, before any operation runs.
///
/// Pure, so the handshake and validation rules are unit-tested here rather than inside the
/// XPC service bundle. The service applies the decision: it replies, and for `replyAndClose`
/// it marks the session refused; `SessionLifetime` below then closes that session once every
/// reply it owes has been handed to the transport, so the rejection is always delivered first
/// (MVP-PLAN.md §3, "Sandbox and XPC boundary").
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

    /// What one session still owes its peer, so a refused session closes exactly once and
    /// never before the rejection it was answered with has been handed to the transport.
    ///
    /// The service calls `began` when a message arrives, `refuse` when a decision refuses the
    /// session, and `finished` once that message's reply has been handed over. `finished`
    /// answers whether this was the last reply a refused session owed, which is the moment to
    /// close it: waiting instead for another message would leave an incompatible connection
    /// open for as long as the app runs, because a client told to stop sends nothing more.
    public struct SessionLifetime: Sendable {
        public private(set) var inFlight = 0
        /// The rejection this session was answered with. The first one stands, so a later
        /// refusal never rewrites why the session is closing.
        public private(set) var refusal: RuntimeEvent?
        /// The close has been taken by one caller, so no message is admitted after it.
        public private(set) var isClosing = false

        public init() {}

        /// One message arrived. Returns how much else the session already owes an answer for,
        /// or `nil` when the session is already closing.
        ///
        /// Admission and the decision to close are one state change, so a message can never be
        /// admitted in the interval between `finished` answering that the session is quiet and
        /// the cancel that follows it: such a message would have been answered and then had
        /// its reply cut off by that cancel, which is the connection interruption the stored
        /// rejection exists to replace.
        public mutating func began() -> Int? {
            guard !isClosing else { return nil }
            inFlight += 1
            return inFlight - 1
        }

        public mutating func refuse(_ rejection: RuntimeEvent) {
            if refusal == nil { refusal = rejection }
        }

        /// One reply has been handed to the transport. Answers whether this caller should
        /// close the session now: it was refused, it owes nothing further, and no other
        /// caller has already taken the close.
        public mutating func finished() -> Bool {
            inFlight -= 1
            guard refusal != nil, inFlight == 0, !isClosing else { return false }
            isClosing = true
            return true
        }
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
    /// It is answered with that same rejection rather than cut off, so a request that was
    /// already pipelined behind the refusal still receives the protocol-mismatch or
    /// unauthorized-caller recovery instead of a bare connection interruption. Closing is not
    /// a decision about this message at all: `SessionLifetime` closes the session once every
    /// reply it owes, this one included, has been handed to the transport.
    public static func refused(_ rejection: RuntimeEvent) -> Decision {
        .reply(rejection)
    }

    /// Applies a session's refusal to a decision already made for one of its messages.
    ///
    /// Two requests can be admitted concurrently and both find the session unrefused; if one
    /// of them then refuses it, the other must not go on to run. The refusal is therefore
    /// applied to the decision immediately before it is acted on, rather than trusted from the
    /// moment the message arrived. Only dispatch is withdrawn: a decision that runs nothing is
    /// already an answer the peer should have.
    /// This is only a pure transformation: a refusal snapshot can still become stale.
    /// Concurrent dispatch must use `RuntimeSessionGate.commit` for atomic registration.
    public static func honoring(_ refusal: RuntimeEvent?, _ decision: Decision) -> Decision {
        guard let refusal, case .dispatch = decision else { return decision }
        return refused(refusal)
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
