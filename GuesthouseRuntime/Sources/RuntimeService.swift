import Foundation
import GuesthouseCore
import GuesthouseRuntimeKit
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
///
/// Queries reply synchronously. Lifecycle operations reply `accepted` once the journal has
/// the operation, then stream progress, status, and the result to the session.
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

    /// What is known about the Tart runtime, filled in by `discoverTart()` after launch.
    private let tartInfo = Mutex<RuntimeVersionInfo.TartRuntimeInfo?>(nil)
    /// The discovery attempt under way, so a burst of requests waits on one rather than
    /// starting one each.
    private let rediscovery = Mutex<DispatchGroup?>(nil)
    /// How long a request waits for a rediscovery before answering with what is known. The
    /// attempt keeps running; this only stops a wedged host from holding the session's message
    /// queue. `version()` carries its own 15-second timeout, so this is the backstop.
    static let rediscoveryWait: DispatchTimeInterval = .seconds(25)
    /// Lifecycle operations, available once a verified runtime bundle exists.
    private let lifecycle = Mutex<EnvironmentLifecycle?>(nil)

    /// Accepts a session and returns a per-session handler that tracks in-flight requests.
    func acceptSession(_ session: XPCSession) -> SessionHandler {
        log.notice(RedactedLine(literal: "session accepted"))
        return SessionHandler(service: self, session: session)
    }

    /// Returns a synchronous reply, or `nil` when the reply is sent later through `message.reply`.
    ///
    /// `refusal` is read rather than passed in, because another request on the same session can
    /// refuse it while this one is still being decoded.
    func handle(_ message: XPCReceivedMessage, session: XPCSession, inFlight: Int, refusal: () -> RuntimeEvent?, refuse: @escaping (RuntimeEvent) -> Void = { _ in }) -> (any Encodable)? {
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
            return reply(RuntimeDispatcher.refused(refused), session: session, message: message, reason: "session refused")
        }
        guard message.senderSatisfies(Self.peerRequirement) else {
            log.error(RedactedLine(literal: "message from a peer that does not satisfy the requirement; closing session"))
            return reply(.replyAndClose(.failed(OperationID(), .unauthorizedCaller)), session: session, message: message, reason: "unauthorized caller", refuse: refuse)
        }
        // The concurrency cap is applied before the request is decoded, so a peer over the cap
        // costs nothing to refuse. Only its version header is read, and only at the cap, so
        // that the refusal is one the peer's own protocol version can decode.
        let clientVersion = { try? message.decode(as: RuntimeRequestEnvelope.Header.self).protocolVersion }
        if let refused = RuntimeDispatcher.admit(inFlight: inFlight, clientVersion: clientVersion) {
            return reply(refused, session: session, message: message, reason: "protocol mismatch over the request cap", refuse: refuse)
        }
        let envelope: RuntimeRequestEnvelope
        do {
            envelope = try message.decode(as: RuntimeRequestEnvelope.self)
        } catch let mismatch as RuntimeRequestEnvelope.ProtocolMismatch {
            // A version-skewed installation is not corrupt input: the client gets the
            // protocol-mismatch error and its reinstall recovery, and the session closes.
            log.error(Self.line("protocol mismatch: client", "\(mismatch.client.rawValue)"))
            return reply(RuntimeDispatcher.mismatch(mismatch.error), session: session, message: message, refuse: refuse)
        } catch {
            // Never log the decoding error text: it can quote the raw offending value.
            log.error(RedactedLine(literal: "undecodable request rejected"))
            if case .reply(let event) = RuntimeDispatcher.undecodable() { return event }
            return RuntimeEvent.failed(OperationID(), .invalidRequest(.malformed))
        }
        // Nothing runs on a refused session. Deciding first and reading the refusal after is
        // deliberate: validating the envelope is the longest step, and one expression would
        // evaluate the refusal before it, honoring an answer that is already stale by the time
        // the decision is acted on.
        let decision = RuntimeDispatcher.decide(envelope, inFlight: inFlight)
        return reply(RuntimeDispatcher.honoring(refusal(), decision), session: session, message: message)
    }

    private func reply(_ decision: RuntimeDispatcher.Decision, session: XPCSession, message: XPCReceivedMessage, reason: String = "protocol mismatch", refuse: @escaping (RuntimeEvent) -> Void = { _ in }) -> (any Encodable)? {
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
            return perform(request, message: message, session: session)
        }
    }

    private func perform(_ request: RuntimeRequest, message: XPCReceivedMessage, session: XPCSession) -> (any Encodable)? {
        switch request {
        case .runtimeVersion:
            // Discovery ran once at launch. A problem the user was told they could retry —
            // storage that was full or unwritable — changes once they act on it, so asking
            // again re-runs discovery, and this reply carries its result: the client's query
            // ends on this one answer, so a cache only a restart could change would make the
            // Retry the user was offered need a second press.
            rediscoverIfRetryable()
            return RuntimeEvent.runtimeVersion(versionInfo)
        case .listEnvironments, .environmentStatus, .startEnvironment, .stopEnvironment, .cancelOperation:
            guard let lifecycle = lifecycle.withLock({ $0 }) else {
                let info = tartInfo.withLock { $0 }
                return RuntimeEvent.failed(OperationID(), info?.problem ?? .runtimeMissing)
            }
            let reply = ReplyBox(message)
            let sink = SessionSink(session: session, log: log)
            Task { await self.performAsync(request, lifecycle: lifecycle, reply: reply, events: sink) }
            return nil
        case .importXcode:
            log.notice(Self.line("operation not implemented yet:", request.caseName))
            return RuntimeEvent.failed(OperationID(), .invalidRequest(.unsupportedOperation))
        }
    }

    private func performAsync(_ request: RuntimeRequest, lifecycle: EnvironmentLifecycle, reply: ReplyBox, events: SessionSink) async {
        do {
            switch request {
            case .listEnvironments:
                reply.send(RuntimeEvent.environments(await lifecycle.environments()))
            case .environmentStatus(let id):
                reply.send(RuntimeEvent.status(try await lifecycle.status(of: id)))
            case .startEnvironment(let id, let options):
                let operation = try await lifecycle.start(id, options: options) { event in events.send(event) }
                reply.send(RuntimeEvent.accepted(operation))
            case .stopEnvironment(let id, let mode):
                let operation = try await lifecycle.stop(id, mode: mode) { event in events.send(event) }
                reply.send(RuntimeEvent.accepted(operation))
            case .cancelOperation(let operation):
                await lifecycle.cancel(operation)
                reply.send(RuntimeEvent.completed(operation))
            case .runtimeVersion, .importXcode:
                reply.send(RuntimeEvent.failed(OperationID(), .invalidRequest(.unsupportedOperation)))
            }
        } catch let error as GuesthouseError {
            reply.send(RuntimeEvent.failed(OperationID(), error))
        } catch {
            log.error("operation failed: \(request.caseName, privacy: .public)")
            reply.send(RuntimeEvent.failed(OperationID(), .invalidRequest(.malformed)))
        }
    }

    func sessionEnded(_ error: XPCRichError) {
        // The rich error's description is opaque and may quote context; log a fixed message.
        log.notice("session ended")
    }

    var versionInfo: RuntimeVersionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return RuntimeVersionInfo(
            serviceVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            serviceBuild: info["CFBundleVersion"] as? String ?? "0",
            protocolVersion: .current,
            tart: tartInfo.withLock { $0 }
        )
    }

    /// Runs discovery again when what is known names a problem the user was told they could
    /// retry, and waits for the attempt before the caller is answered.
    ///
    /// Waiting is the point: the reply to a `runtimeVersion` request is the only answer that
    /// request ever gets, so returning the cached failure would leave the Retry the user was
    /// offered needing a second press to show what changed. A burst of requests joins the one
    /// attempt rather than starting one each.
    func rediscoverIfRetryable() {
        let attempt: (group: DispatchGroup, isMine: Bool)? = rediscovery.withLock { running in
            if let running { return (running, false) }
            guard tartInfo.withLock({ $0?.problem?.recoveryActions.contains(.retry) ?? false }) else { return nil }
            let group = DispatchGroup()
            group.enter()
            running = group
            return (group, true)
        }
        guard let attempt else { return }
        if attempt.isMine {
            // Detached, so the discovery does not inherit this handler's context, and off this
            // thread, which is the one waiting below.
            Task.detached { [self] in
                await discoverTart()
                rediscovery.withLock { $0 = nil }
                attempt.group.leave()
            }
        }
        _ = attempt.group.wait(timeout: .now() + Self.rediscoveryWait)
    }

    /// Locates the pinned Tart bundle under runtime storage, verifies its signature and
    /// entitlements, asks it for its version, and, when it verified, brings up the lifecycle
    /// (loading state, adopting hand-created VMs, reconciling recorded processes). Runs once
    /// after launch; until it finishes, `runtimeVersion` reports the runtime as not located
    /// and lifecycle requests fail with `runtimeMissing`.
    func discoverTart() async {
        let storage: RuntimeStorage
        do {
            storage = try RuntimeStorage(root: try RuntimeStorage.defaultRoot())
        } catch {
            // A storage problem is not a missing runtime: reinstalling Tart cannot fix an
            // unwritable or unsafe storage directory, so the storage error is reported as it
            // is, with its own recovery actions.
            log.error(Self.line("runtime storage unavailable:", Self.describe(error)))
            // The storage error keeps its own recovery: freeing space and retrying discovery
            // are what help, and neither is what a missing runtime would offer.
            let problem: GuesthouseError = switch error as? RuntimeStorageError {
            case .unwritable(_, _)?: .runtimeStorageUnavailable(reason: SanitizedText((error as? RuntimeStorageError)?.userMessage ?? "", limit: 200), problem: .unwritable)
            case .insecureDirectory(_, _)?: .runtimeStorageUnavailable(reason: SanitizedText((error as? RuntimeStorageError)?.userMessage ?? "", limit: 200), problem: .unsafeLocation)
            case nil: .runtimeMissing
            }
            tartInfo.withLock { $0 = .init(version: nil, verified: false, problem: problem) }
            return
        }
        guard let bundle = TartBundle.locate(in: storage) else {
            log.notice(RedactedLine(literal: "no Tart bundle at the pinned location"))
            tartInfo.withLock { $0 = .init(version: nil, verified: false, problem: .runtimeMissing) }
            return
        }
        // Never execute a bundle that failed verification: only its metadata is reported.
        let verification: TartVerification
        do {
            verification = try bundle.verify()
        } catch {
            log.error(Self.line("Tart bundle failed verification:", Self.describe(error)))
            let claimed = bundle.claimedVersion?.description
            // A version mismatch is an incompatibility; anything else is a failed check on the
            // bundle itself and is named as such.
            let problem: GuesthouseError = if case .versionMismatch = error {
                .runtimeIncompatible(found: claimed.map { SanitizedText($0) }, required: SanitizedText(TartPin.releaseTag))
            } else {
                .runtimeVerificationFailed(check: Self.check(for: error))
            }
            tartInfo.withLock { $0 = .init(version: claimed, verified: false, problem: problem) }
            return
        }
        // The identity verification recorded, so a replacement before launch is refused. It is
        // not read again here: a second read could find a link where the verified bundle was,
        // and an identity that cannot be read would disable the check rather than fail it.
        let backend = TartBackend(bundle: bundle, storage: storage, runner: ProcessRunner(), verifiedBundle: verification.bundle)
        let version: TartVersion
        do {
            version = try await backend.version()
        } catch TartInvocationError.runtimeReplaced {
            log.error(RedactedLine(literal: "the Tart bundle was replaced after it was verified"))
            // An integrity failure, not an unknown version: reporting `verified: true` would
            // tell the user the bundle now on disk passed its checks, when the check is exactly
            // what refused it.
            tartInfo.withLock { $0 = .init(version: bundle.claimedVersion?.description, verified: false, problem: .runtimeVerificationFailed(check: .identity)) }
            return
        } catch {
            log.error(Self.line("verified Tart bundle could not report its version:", Self.describe(error)))
            // A host-runtime failure: the bundle verified but did not answer, so its version is
            // unknown and repair reinstalls it. Never a guest tool problem.
            tartInfo.withLock { $0 = .init(version: bundle.claimedVersion?.description, verified: true, problem: .runtimeIncompatible(found: nil, required: SanitizedText(TartPin.releaseTag))) }
            return
        }
        guard version == TartPin.version else {
            log.error(Self.line("pinned Tart not found; located instead:", "\(version.description) rather than \(TartPin.releaseTag)"))
            tartInfo.withLock { $0 = .init(version: version.description, verified: true, problem: .runtimeIncompatible(found: SanitizedText(version.description), required: SanitizedText(TartPin.releaseTag))) }
            return
        }
        tartInfo.withLock { $0 = .init(version: version.description, verified: true) }
        log.notice(Self.line("Tart located and verified:", version.description))
        do {
            let supervisor = OperationSupervisor(store: try ProcessIdentityStore(directory: storage.url(for: .state)))
            let store = try StateStore(rootURL: storage.url(for: .state))
            let lifecycle = EnvironmentLifecycle(dependencies: .init(backend: backend, supervisor: supervisor, store: store))
            try await lifecycle.prepare()
            self.lifecycle.withLock { $0 = lifecycle }
            let count = await lifecycle.environments().count
            log.notice(Self.line("lifecycle ready; environments:", "\(count)"))
        } catch {
            log.error(Self.line("lifecycle could not start:", Self.describe(error)))
            tartInfo.withLock { $0 = .init(version: version.description, verified: true, problem: .operationOutcomeUnknown(OperationID())) }
        }
    }

    /// Which bundle check a verification error names, for the user-facing error.
    static func check(for error: any Error) -> GuesthouseError.RuntimeVerificationCheck {
        switch error as? TartVerificationError {
        case .bundleMissing, .infoPlistUnreadable, .executableMissing: .layout
        // A bundle swapped while it was being checked is an identity failure, not a layout
        // one: it is complete, it is just not the one that passed.
        case .bundleIdentifierMismatch, .bundleReplaced: .identity
        case .signatureInvalid, .requirementNotMet: .signature
        case .entitlementMissing: .entitlements
        case .digestMismatch, .archiveUnreadable: .digest
        case .versionMismatch, .none: .signature
        }
    }

    /// Error text for the log: the error's case name only, never its payload, which can hold
    /// paths or process output.
    static func describe(_ error: any Error) -> String {
        let text = String(describing: error)
        return String(text.prefix { $0 != "(" && $0 != ":" })
    }

    /// Per-session state: the in-flight request count used for the concurrency cap.
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
}

    func sessionEnded(_ error: XPCRichError) {
        // The rich error's description is opaque and may quote context; log a fixed message.
        log.notice(RedactedLine(literal: "session ended"))
/// Lets a message be answered after an asynchronous operation. `XPCReceivedMessage` is only
/// ever touched from the task that replies.
final class ReplyBox: @unchecked Sendable {
    private let message: XPCReceivedMessage
    private let replied = Mutex(false)

    init(_ message: XPCReceivedMessage) { self.message = message }

    func send(_ event: RuntimeEvent) {
        let first = replied.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard first else { return }
        message.reply(event)
    }
}

/// Pushes streamed events to the client session. Send failures are logged (redacted); the
/// client treats a dropped session as an unknown outcome and re-queries status.
final class SessionSink: @unchecked Sendable {
    private let session: XPCSession
    private let log: Logger

    init(session: XPCSession, log: Logger) {
        self.session = session
        self.log = log
    }

    func send(_ event: RuntimeEvent) {
        do {
            try session.send(event)
        } catch {
            log.error("could not push \(event.caseName, privacy: .public) to the client")
        }
    }
}
