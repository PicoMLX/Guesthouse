import Foundation
import GuesthouseCore
import OSLog
import Synchronization
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
    // A present value with no version, capabilities, or problem means discovery is still in
    // progress. Keeping that state explicit lets the listener remain responsive while an
    // external executable is interrogated.
    private let lumeInfo = Mutex<RuntimeVersionInfo.LumeRuntimeInfo?>(
        LumeDiscoveryReport.checking
    )

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
        log.notice(RedactedLine(literal: "session accepted"))
        return SessionHandler(service: self, session: session)
    }

    /// One reply per request. Streaming events for long operations arrive with #25.
    ///
    /// `refusal` is read rather than passed in, because another request on the same session can
    /// refuse it while this one is still being decoded.
    func handle(_ message: XPCReceivedMessage, inFlight: Int, refusal: () -> RuntimeEvent?, refuse: (RuntimeEvent) -> Void = { _ in }) -> RuntimeEvent? {
        // A message that asks for no reply is never decoded or dispatched. An operation whose
        // ID, acceptance, and terminal event have nowhere to go is a host mutation the client
        // could neither follow nor cancel, and the client would have no record that it ran.
        guard message.expectsReply else {
            // Nothing can be sent back, but the sender still has to be the one the requirement
            // names: dropping the message silently would leave a peer that fails the check
            // holding the session and free to keep sending. The refusal is recorded instead of
            // replied, and the session closes as soon as it owes nothing further.
            guard message.senderSatisfies(Self.peerRequirement) else {
                log.error(RedactedLine(literal: "one-way message from a peer that does not satisfy the requirement; closing session"))
                refuse(.failed(OperationID(), .unauthorizedCaller))
                return nil
            }
            log.error(RedactedLine(literal: "one-way message rejected before anything ran"))
            return nil
        }
        // A session already answered with a rejection is told again rather than cut off, so a
        // request pipelined behind the refusal still gets an actionable answer. The session is
        // closed by its lifetime once every reply it owes has been handed over.
        if let refused = refusal() {
            return reply(RuntimeDispatcher.refused(refused), reason: "session refused")
        }
        guard message.senderSatisfies(Self.peerRequirement) else {
            log.error(RedactedLine(literal: "message from a peer that does not satisfy the requirement; closing session"))
            return reply(.replyAndClose(.failed(OperationID(), .unauthorizedCaller)), reason: "unauthorized caller", refuse: refuse)
        }
        // The concurrency cap is applied before the request is decoded, so a peer over the cap
        // costs nothing to refuse. Only its version header is read, and only at the cap, so
        // that the refusal is one the peer's own protocol version can decode.
        let clientVersion = { try? message.decode(as: RuntimeRequestEnvelope.Header.self).protocolVersion }
        if let refused = RuntimeDispatcher.admit(inFlight: inFlight, clientVersion: clientVersion) {
            return reply(refused, reason: "protocol mismatch over the request cap", refuse: refuse)
        }
        let envelope: RuntimeRequestEnvelope
        do {
            envelope = try message.decode(as: RuntimeRequestEnvelope.self)
        } catch {
            // Never log the decoding error text: it can quote the raw offending value.
            log.error(RedactedLine(literal: "undecodable request rejected"))
            // Typed protocol mismatches refuse this session; its lifetime still waits for
            // every outstanding reply before cancellation.
            return reply(RuntimeDispatcher.decodingFailure(error), refuse: refuse)
        }
        // Nothing runs on a refused session. Deciding first and reading the refusal after is
        // deliberate: validating the envelope is the longest step, and one expression would
        // evaluate the refusal before it, honoring an answer that is already stale by the time
        // the decision is acted on.
        let decision = RuntimeDispatcher.decide(envelope, inFlight: inFlight)
        return reply(RuntimeDispatcher.honoring(refusal(), decision))
    }

    private func reply(_ decision: RuntimeDispatcher.Decision, reason: String = "protocol mismatch", refuse: (RuntimeEvent) -> Void = { _ in }) -> RuntimeEvent? {
        switch decision {
        case .reply(let event):
            log.error(Self.line("rejected request:", event.caseName))
            return event
        case .replyAndClose(let event):
            log.error(Self.line("refusing session:", reason))
            // The session is marked refused rather than cancelled here: cancelling before this
            // rejection has been handed to the transport would discard the very answer the
            // client needs. `SessionHandler` closes it once the session owes nothing more.
            refuse(event)
            return event
        case .dispatch(let request):
            return perform(request)
        }
    }

    private func perform(_ request: RuntimeRequest) -> RuntimeEvent {
        switch request {
        case .runtimeVersion:
            return .runtimeVersion(versionInfo)
        case .environmentStatus, .startEnvironment, .stopEnvironment, .importXcode, .cancelOperation:
            log.notice(Self.line("operation not implemented yet:", request.caseName))
            return .failed(OperationID(), .invalidRequest(.unsupportedOperation))
        }
    }

    var versionInfo: RuntimeVersionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return RuntimeVersionInfo(
            serviceVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            serviceBuild: info["CFBundleVersion"] as? String ?? "0",
            protocolVersion: .current,
            tart: nil,
            lume: lumeInfo.withLock { $0 }
        )
    }

    /// Runs in the background after the listener activates. Version replies report `checking`
    /// until it finishes, and only a bundle that passes static verification is executed.
    func discoverLume() async {
        let storage: RuntimeStorage
        do {
            storage = try RuntimeStorage(root: try RuntimeStorage.defaultRoot())
        } catch let error as RuntimeStorageError {
            let diagnostic = LumeDiscoveryReport.redactedDiagnostic(for: error)
            log.error(Self.line("runtime storage unavailable:", diagnostic.value))
            lumeInfo.withLock { $0 = LumeDiscoveryReport.storageUnavailable(error) }
            return
        } catch {
            let diagnostic = LumeDiscoveryReport.redactedDiagnostic(for: error)
            log.error(Self.line("runtime storage discovery failed:", diagnostic.value))
            lumeInfo.withLock {
                $0 = .init(version: nil, verified: false, problem: .runtimeProbeFailed)
            }
            return
        }
        let bundle: LumeBundle
        do {
            guard let located = try LumeBundle.locate(in: storage) else {
                log.notice(RedactedLine(literal: "no Lume bundle at the pinned location"))
                lumeInfo.withLock { $0 = LumeDiscoveryReport.missing }
                return
            }
            bundle = located
        } catch let error as RuntimeStorageError {
            let diagnostic = LumeDiscoveryReport.redactedDiagnostic(for: error)
            log.error(Self.line("unsafe Lume storage path rejected:", diagnostic.value))
            lumeInfo.withLock { $0 = LumeDiscoveryReport.storageUnavailable(error) }
            return
        } catch {
            let diagnostic = LumeDiscoveryReport.redactedDiagnostic(for: error)
            log.error(Self.line("Lume location discovery failed:", diagnostic.value))
            lumeInfo.withLock {
                $0 = .init(version: nil, verified: false, problem: .runtimeProbeFailed)
            }
            return
        }
        let verifiedBundle: VerifiedLumeBundle
        do {
            verifiedBundle = try bundle.verify()
        } catch {
            let diagnostic = LumeDiscoveryReport.redactedDiagnostic(for: error)
            log.error(Self.line("Lume bundle failed verification:", diagnostic.value))
            lumeInfo.withLock { $0 = LumeDiscoveryReport.rejectedBundle(error) }
            return
        }
        do {
            let result = try await LumeBackend(bundle: verifiedBundle, storage: storage, runner: ProcessRunner()).probe()
            lumeInfo.withLock { $0 = LumeDiscoveryReport.succeeded(result) }
            log.notice(RedactedLine(literal: "Lume candidate located, verified, and probed"))
        } catch {
            let diagnostic = LumeDiscoveryReport.redactedDiagnostic(for: error)
            log.error(Self.line("verified Lume bundle probe failed:", diagnostic.value))
            lumeInfo.withLock {
                $0 = LumeDiscoveryReport.failedProbe(error, claimedVersion: verifiedBundle.version)
            }
        }
    }

    /// Per-session state: what the session still owes its peer, and the rejection it was
    /// answered with. The rules live in `RuntimeDispatcher.SessionLifetime`, which is unit
    /// tested; this class only holds them under a lock and applies the outcome.
    final class SessionHandler: XPCPeerHandler, @unchecked Sendable {
        private let service: RuntimeService
        private let session: XPCSession
        private let lock = NSLock()
        private var lifetime = RuntimeDispatcher.SessionLifetime()

        init(service: RuntimeService, session: XPCSession) {
            self.service = service
            self.session = session
        }

        func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
            // The count taken here excludes this message, so it says how much else the
            // session still owes an answer for. A session whose close has already been taken
            // admits nothing: answering here would race that cancel and hand the peer a
            // connection interruption in place of the rejection it is owed.
            guard let others = lock.withLock({ lifetime.began() }) else { return nil }
            let answer = service.handle(message, inFlight: others, refusal: { self.refusalEvent }) { [weak self] event in
                self?.markRefused(with: event)
            }
            // The reply is handed to the transport here rather than by returning it: a
            // returned value is only sent once this method has returned, by which time this
            // request no longer counts as outstanding and a concurrent message could already
            // have closed the session with the rejection still unsent. A message that asked
            // for no reply was answered with nothing above.
            if let answer { message.reply(answer) }
            // A refused session closes as soon as it owes nothing further. Waiting instead for
            // another message would keep an incompatible connection open for as long as the
            // app runs, because a client that has been told to stop sends nothing more.
            if lock.withLock({ lifetime.finished() }) {
                session.cancel(reason: "session refused")
            }
            return nil
        }

        /// The rejection this session was answered with, if any. Also a test seam.
        var refusalEvent: RuntimeEvent? { lock.withLock { lifetime.refusal } }

        private func markRefused(with event: RuntimeEvent) {
            lock.withLock { lifetime.refuse(event) }
        }

        func handleCancellation(error: XPCRichError) {
            service.sessionEnded(error)
        }
    }

    func sessionEnded(_ error: XPCRichError) {
        // The rich error's description is opaque and may quote context; log a fixed message.
        log.notice(RedactedLine(literal: "session ended"))
    }
}
