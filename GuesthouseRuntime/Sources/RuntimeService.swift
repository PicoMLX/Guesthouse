import Foundation
import GuesthouseCore
import OSLog
import XPC

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

    private let log = Logger(subsystem: serviceName, category: "service")

    /// Accepts a session and returns a per-session handler that tracks in-flight requests.
    func acceptSession(_ session: XPCSession) -> SessionHandler {
        log.notice("session accepted")
        return SessionHandler(service: self, session: session)
    }

    /// One reply per request. Streaming events for long operations arrive with #25.
    func handle(_ message: XPCReceivedMessage, session: XPCSession, inFlight: Int) -> (any Encodable)? {
        guard message.senderSatisfies(Self.peerRequirement) else {
            log.error("message from a peer that does not satisfy the requirement; closing session")
            return reply(.replyAndClose(.failed(OperationID(), .unauthorizedCaller)), session: session, reason: "unauthorized caller")
        }
        // The concurrency cap is applied before the decoder runs, so a peer over the cap
        // costs nothing to refuse.
        if let refused = RuntimeDispatcher.admit(inFlight: inFlight) {
            return reply(refused, session: session)
        }
        let envelope: RuntimeRequestEnvelope
        do {
            envelope = try message.decode(as: RuntimeRequestEnvelope.self)
        } catch let mismatch as RuntimeRequestEnvelope.ProtocolMismatch {
            // A version-skewed installation is not corrupt input: the client gets the
            // protocol-mismatch error and its reinstall recovery, and the session closes.
            log.error("protocol mismatch: client \(mismatch.client.rawValue, privacy: .public)")
            return reply(RuntimeDispatcher.mismatch(mismatch.error), session: session)
        } catch {
            // Never log the decoding error text: it can quote the raw offending value.
            log.error("undecodable request rejected")
            return reply(RuntimeDispatcher.decodingFailure(error), session: session)
        }
        return reply(RuntimeDispatcher.decide(envelope, inFlight: inFlight), session: session)
    }

    private func reply(_ decision: RuntimeDispatcher.Decision, session: XPCSession, reason: String = "protocol mismatch") -> (any Encodable)? {
        switch decision {
        case .reply(let event):
            log.error("rejected request: \(event.caseName, privacy: .public)")
            return event
        case .replyAndClose(let event):
            log.error("closing session: \(reason, privacy: .public)")
            // The reply is only sent once this handler returns, so the session is closed
            // afterwards: cancelling here would discard the answer the client needs.
            Self.closeQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                session.cancel(reason: reason)
            }
            return event
        case .dispatch(let request):
            return perform(request)
        }
    }

    /// Where deferred session closes run, so a reply is never cancelled before it is sent.
    private static let closeQueue = DispatchQueue(label: "\(serviceName).close")

    private func perform(_ request: RuntimeRequest) -> RuntimeEvent {
        switch request {
        case .runtimeVersion:
            return .runtimeVersion(Self.versionInfo)
        case .environmentStatus, .startEnvironment, .stopEnvironment, .importXcode, .cancelOperation:
            log.notice("operation not implemented yet: \(request.caseName, privacy: .public)")
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

        init(service: RuntimeService, session: XPCSession) {
            self.service = service
            self.session = session
        }

        func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
            let count = lock.withLock { inFlight += 1; return inFlight - 1 }
            defer { lock.withLock { inFlight -= 1 } }
            return service.handle(message, session: session, inFlight: count)
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
