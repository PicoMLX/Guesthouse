import Foundation
import GuesthouseCore
import OSLog
import XPC

/// The service's only log sink.
///
/// It accepts `RedactedLine` and nothing else, so a diagnostic built from guest, CLI, or
/// request text cannot reach the system log unredacted (MVP-PLAN.md §3, "Local storage"). The
/// text is written as public on purpose: it has already passed the redaction layer, and hiding
/// it would only make a line that is safe to read unreadable in a diagnostics report.
struct ServiceLog: Sendable {
    private let log: Logger

    init(category: String) {
        log = Logger(subsystem: RuntimeService.serviceName, category: category)
    }

    func error(_ line: RedactedLine) { log.error("\(line.text, privacy: .public)") }
    func notice(_ line: RedactedLine) { log.notice("\(line.text, privacy: .public)") }
}

/// Decodes envelopes, dispatches named operations, and replies with `RuntimeEvent`s.
///
/// Callers are authenticated twice: the listener only accepts sessions whose peer is signed by
/// this app's team with this app's signing identifier, and every message is checked again
/// against the same requirement before it is decoded (MVP-PLAN.md §3, "Authenticate callers").
final class RuntimeService: Sendable {
    static let serviceName = "com.starlingprotocol.Guesthouse.Runtime"
    /// The only process allowed to talk to this service.
    static let clientSigningIdentifier = "com.starlingprotocol.Guesthouse"
    /// Same Team ID as this service, and exactly the app's signing identifier. Development and
    /// distribution builds of the app both satisfy it; nothing else does.
    static let peerRequirement = XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier: clientSigningIdentifier)

    private let log = ServiceLog(category: "service")

    /// A diagnostic that carries a value, as a line the sink accepts.
    ///
    /// The values interpolated today are the service's own case names and protocol numbers,
    /// but they go through `Redactor` like any other text, so a line built later from guest,
    /// CLI, or request data cannot reach the log unredacted.
    private static func line(_ message: StaticString, _ value: String) -> RedactedLine {
        var state = Redactor.StreamState()
        return Redactor().redact(line: "\(message) \(value)", state: &state)
    }

    /// Accepts a session and returns a per-session handler that tracks in-flight requests.
    func acceptSession(_ session: XPCSession) -> SessionHandler {
        log.notice("session accepted")
        return SessionHandler(service: self, session: session)
    }

    /// One reply per request. Streaming events for long operations arrive with #25.
    func handle(_ message: XPCReceivedMessage, session: XPCSession, inFlight: Int, refusal: RuntimeEvent?, refuse: (RuntimeEvent) -> Void = { _ in }) -> (any Encodable)? {
        // A session already answered with a rejection is closed here rather than on a timer,
        // and only once nothing else is outstanding on it: requests are pipelined, so a new
        // message is no proof that the rejection has been delivered, and cancelling while
        // another request is in flight could still discard it.
        if let refusal {
            return reply(RuntimeDispatcher.refused(refusal, inFlight: inFlight), session: session, reason: "session refused")
        }
        guard message.senderSatisfies(Self.peerRequirement) else {
            log.error("message from a peer that does not satisfy the requirement; closing session")
            return reply(.replyAndClose(.failed(OperationID(), .unauthorizedCaller)), session: session, reason: "unauthorized caller", refuse: refuse)
        }
        // The concurrency cap is applied before the request is decoded, so a peer over the cap
        // costs nothing to refuse. Only its version header is read, and only at the cap, so
        // that the refusal is one the peer's own protocol version can decode.
        let clientVersion = { try? message.decode(as: RuntimeRequestEnvelope.Header.self).protocolVersion }
        if let refused = RuntimeDispatcher.admit(inFlight: inFlight, clientVersion: clientVersion) {
            return reply(refused, session: session, reason: "protocol mismatch over the request cap", refuse: refuse)
        }
        let envelope: RuntimeRequestEnvelope
        do {
            envelope = try message.decode(as: RuntimeRequestEnvelope.self)
        } catch let mismatch as RuntimeRequestEnvelope.ProtocolMismatch {
            // A version-skewed installation is not corrupt input: the client gets the
            // protocol-mismatch error and its reinstall recovery, and the session closes.
            log.error(Self.line("protocol mismatch: client", "\(mismatch.client.rawValue)"))
            return reply(RuntimeDispatcher.mismatch(mismatch.error), session: session, refuse: refuse)
        } catch {
            // Never log the decoding error text: it can quote the raw offending value.
            log.error(RedactedLine(literal: "undecodable request rejected"))
            return reply(RuntimeDispatcher.undecodable(), session: session)
        }
        return reply(RuntimeDispatcher.decide(envelope, inFlight: inFlight), session: session)
    }

    private func reply(_ decision: RuntimeDispatcher.Decision, session: XPCSession, reason: String = "protocol mismatch", refuse: (RuntimeEvent) -> Void = { _ in }) -> (any Encodable)? {
        switch decision {
        case .reply(let event):
            log.error(Self.line("rejected request:", event.caseName))
            return event
        case .replyAndClose(let event):
            log.error(Self.line("refusing session:", reason))
            // The reply is only sent once this handler returns, so the session cannot be
            // cancelled here: that would discard the answer the client needs, and closing
            // after a delay only guesses when delivery finished. The session is marked
            // instead, refused for everything that follows, and closed by the first later
            // message that finds nothing else outstanding on it.
            refuse(event)
            return event
        case .close:
            log.error("closing a refused session: \(reason, privacy: .public)")
            session.cancel(reason: reason)
            return nil
        case .dispatch(let request):
            return perform(request)
        }
    }

    private func perform(_ request: RuntimeRequest) -> RuntimeEvent {
        switch request {
        case .runtimeVersion:
            return .runtimeVersion(Self.versionInfo)
        case .environmentStatus, .startEnvironment, .stopEnvironment, .importXcode, .cancelOperation:
            log.notice(Self.line("operation not implemented yet:", request.caseName))
            return .failed(OperationID(), .invalidRequest(.unsupportedOperation))
        }
    }

    static var versionInfo: RuntimeVersionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return RuntimeVersionInfo(
            serviceVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            serviceBuild: info["CFBundleVersion"] as? String ?? "0",
            protocolVersion: .current,
            tart: nil
        )
    }

    /// Per-session state: the in-flight request count used for the concurrency cap.
    final class SessionHandler: XPCPeerHandler, @unchecked Sendable {
        private let service: RuntimeService
        private let session: XPCSession
        private let lock = NSLock()
        private var inFlight = 0
        /// The rejection this session was answered with, once it has been. It is repeated for
        /// anything that arrives while other requests are still outstanding, and the session
        /// closes on the first message that finds it quiet, so the rejection is never cut off
        /// before it is delivered.
        private var refusal: RuntimeEvent?

        init(service: RuntimeService, session: XPCSession) {
            self.service = service
            self.session = session
        }

        func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
            // The count taken here excludes this message, so it says how much else the
            // session still owes an answer for.
            let (others, refusal) = lock.withLock { inFlight += 1; return (inFlight - 1, self.refusal) }
            defer { lock.withLock { inFlight -= 1 } }
            return service.handle(message, session: session, inFlight: others, refusal: refusal) { [weak self] event in
                self?.markRefused(with: event)
            }
        }

        /// Test seam: the rejection this session was answered with, if any.
        var refusalEvent: RuntimeEvent? { lock.withLock { refusal } }

        private func markRefused(with event: RuntimeEvent) {
            // Two requests can be refused at once; the first reason is the one the peer keeps
            // being told, so a later refusal never rewrites why the session is closing.
            lock.withLock { if refusal == nil { refusal = event } }
        }

        func handleCancellation(error: XPCRichError) {
            service.sessionEnded(error)
        }
    }

    func sessionEnded(_ error: XPCRichError) {
        // The rich error's description is opaque and may quote context; log a fixed message.
        log.notice("session ended")
    }
}
