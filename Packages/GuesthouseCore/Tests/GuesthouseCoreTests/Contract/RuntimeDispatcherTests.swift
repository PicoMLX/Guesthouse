import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeDispatcherTests {
    let environment = EnvironmentID()

    @Test func validEnvelopeIsDispatched() {
        let decision = RuntimeDispatcher.decide(RuntimeRequestEnvelope(request: .runtimeVersion), inFlight: 0)
        #expect(decision == .dispatch(.runtimeVersion))
    }

    @Test func protocolMismatchRepliesAndClosesTheSession() {
        let envelope = RuntimeRequestEnvelope(protocolVersion: RuntimeProtocolVersion(RuntimeProtocolVersion.current.rawValue + 1), request: .runtimeVersion)
        guard case .replyAndClose(.failed(_, let error)) = RuntimeDispatcher.decide(envelope, inFlight: 0) else { Issue.record("expected replyAndClose"); return }
        #expect(error == .protocolMismatch(client: RuntimeProtocolVersion.current.rawValue + 1, service: RuntimeProtocolVersion.current.rawValue))
    }

    @Test func invalidOptionsAreRejectedWithoutClosing() {
        let envelope = RuntimeRequestEnvelope(request: .startEnvironment(environment, StartOptions(ipWait: .seconds(10_000))))
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(envelope, inFlight: 0) else { Issue.record("expected reply"); return }
        #expect(error == .invalidRequest(.malformed))
    }

    @Test func tooManyInFlightRequestsAreRefused() {
        let envelope = RuntimeRequestEnvelope(request: .environmentStatus(environment))
        #expect(RuntimeDispatcher.decide(envelope, inFlight: RuntimeDispatcher.maximumInFlightRequestsPerSession - 1) == .dispatch(.environmentStatus(environment)))
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(envelope, inFlight: RuntimeDispatcher.maximumInFlightRequestsPerSession) else { Issue.record("expected refusal"); return }
        #expect(error == .invalidRequest(.tooManyInFlight))
    }

    @Test func protocolMismatchDuringDecodingRepliesAndClosesTheSession() {
        let clientVersion = RuntimeProtocolVersion(RuntimeProtocolVersion.current.rawValue - 1)
        let mismatch = RuntimeRequestEnvelope.ProtocolMismatch(client: clientVersion)
        guard case .replyAndClose(.failed(_, let error)) = RuntimeDispatcher.decodingFailure(mismatch) else { Issue.record("expected replyAndClose"); return }
        #expect(error == .protocolMismatch(client: clientVersion.rawValue, service: RuntimeProtocolVersion.current.rawValue))
    }

    @Test func otherDecodingFailuresAreMalformed() {
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decodingFailure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "secret input"))) else { Issue.record("expected reply"); return }
        #expect(error == .invalidRequest(.malformed))
    }
    @Test func anOverCapPeerIsRefusedBeforeAnythingIsDecoded() {
        #expect(RuntimeDispatcher.admit(inFlight: 0, clientVersion: { .current }) == nil)
        guard case .reply(.failed(_, let error))? = RuntimeDispatcher.admit(inFlight: RuntimeDispatcher.maximumInFlightRequestsPerSession, clientVersion: { .current }) else {
            Issue.record("expected a refusal at the cap"); return
        }
        #expect(error == .invalidRequest(.tooManyInFlight))
    }

    /// `tooManyInFlight` is a protocol 2 reason, so a peer on an older version would decode
    /// the refusal as garbage. It gets the mismatch it can act on instead.
    @Test func anOverCapPeerOnAnotherProtocolGetsTheMismatchItCanDecode() {
        let older = RuntimeProtocolVersion(RuntimeProtocolVersion.current.rawValue - 1)
        guard case .replyAndClose(.failed(_, let error))? = RuntimeDispatcher.admit(inFlight: RuntimeDispatcher.maximumInFlightRequestsPerSession, clientVersion: { older }) else {
            Issue.record("expected the protocol mismatch"); return
        }
        #expect(error == .protocolMismatch(client: older.rawValue, service: RuntimeProtocolVersion.current.rawValue))
    }

    @Test func anOverCapPeerWithAnUnreadableHeaderIsRefusedAsMalformed() {
        guard case .reply(.failed(_, let error))? = RuntimeDispatcher.admit(inFlight: RuntimeDispatcher.maximumInFlightRequestsPerSession, clientVersion: { nil }) else {
            Issue.record("expected a refusal at the cap"); return
        }
        #expect(error == .invalidRequest(.malformed), "every protocol version can read this one")
    }

    /// The cap has to stay cheap: nothing about the message is read until it is exceeded.
    @Test func theVersionHeaderIsReadOnlyOnceTheCapIsExceeded() {
        var reads = 0
        #expect(RuntimeDispatcher.admit(inFlight: RuntimeDispatcher.maximumInFlightRequestsPerSession - 1, clientVersion: { reads += 1; return .current }) == nil)
        #expect(reads == 0, "an admitted request never pays for a header read")
        _ = RuntimeDispatcher.admit(inFlight: RuntimeDispatcher.maximumInFlightRequestsPerSession, clientVersion: { reads += 1; return .current })
        #expect(reads == 1, "the refusal reads the header once, and never the request")
    }

    @Test func aRequestPipelinedBehindARefusalIsStillAnswered() {
        let rejection = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        #expect(RuntimeDispatcher.refused(rejection) == .reply(rejection), "the peer is told again rather than cut off")
    }

    /// The rejection is delivered before the session goes away: the request that carried it
    /// stops counting only once its reply has been handed over, and the close happens then.
    @Test func aRefusedSessionClosesWhenItOwesNothingFurther() {
        var lifetime = RuntimeDispatcher.SessionLifetime()
        let others = lifetime.began()
        lifetime.refuse(.failed(OperationID(), .unauthorizedCaller))
        let closes = lifetime.finished()
        #expect(others == 0, "the first message finds the session quiet")
        #expect(closes, "no other message is needed to close a refused session")
    }

    @Test func aRefusedSessionStaysOpenWhileAnotherReplyIsOutstanding() {
        var lifetime = RuntimeDispatcher.SessionLifetime()
        _ = lifetime.began()
        let others = lifetime.began()
        lifetime.refuse(.failed(OperationID(), .unauthorizedCaller))
        let afterRefusal = lifetime.finished()
        let afterLast = lifetime.finished()
        #expect(others == 1, "the second message finds the first still outstanding")
        #expect(!afterRefusal, "closing now would discard the answer the other request is owed")
        #expect(afterLast, "the last reply handed over closes the session")
    }

    @Test func theFirstRefusalIsTheReasonThePeerKeepsBeingTold() {
        var lifetime = RuntimeDispatcher.SessionLifetime()
        let first = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        _ = lifetime.began()
        lifetime.refuse(first)
        lifetime.refuse(.failed(OperationID(), .protocolMismatch(client: 1, service: 2)))
        #expect(lifetime.refusal == first, "a later refusal never rewrites why the session is closing")
    }

    @Test func aRefusalStopsAConcurrentlyAdmittedRequestFromRunning() {
        let rejection = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        let dispatch = RuntimeDispatcher.Decision.dispatch(.startEnvironment(EnvironmentID(), StartOptions()))
        #expect(RuntimeDispatcher.honoring(rejection, dispatch) == .reply(rejection), "a request admitted before the refusal must not still run")
        #expect(RuntimeDispatcher.honoring(nil, dispatch) == dispatch, "an unrefused session dispatches as decided")
        let answered = RuntimeDispatcher.Decision.reply(.failed(OperationID(), .invalidRequest(.malformed)))
        #expect(RuntimeDispatcher.honoring(rejection, answered) == answered, "a decision that runs nothing is left alone")
    }

    /// Closing and admitting are one decision. A message admitted in between would be answered
    /// and then have its reply discarded by the cancel that follows, which is exactly the
    /// connection interruption the stored rejection exists to replace.
    @Test func aSessionThatHasTakenItsCloseAdmitsNothingFurther() {
        var lifetime = RuntimeDispatcher.SessionLifetime()
        _ = lifetime.began()
        lifetime.refuse(.failed(OperationID(), .unauthorizedCaller))
        let closes = lifetime.finished()
        let admitted = lifetime.began()
        #expect(closes, "the last reply handed over closes the session")
        #expect(lifetime.isClosing)
        #expect(admitted == nil, "a message admitted after the close would race the cancel")
        #expect(lifetime.inFlight == 0, "a message that was never admitted owes no reply")
    }

    @Test func anUnrefusedSessionIsNeverClosedByItsLifetime() {
        var lifetime = RuntimeDispatcher.SessionLifetime()
        _ = lifetime.began()
        let closes = lifetime.finished()
        #expect(!closes)
        #expect(lifetime.refusal == nil)
    }

    @Test func anOversizedEnvelopeIsRefusedBeforeItIsDispatched() {
        let huge = String(repeating: "a", count: RequestValidator.maximumEncodedSize)
        let envelope = RuntimeRequestEnvelope(request: .importXcode(EnvironmentID(), FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app", expectedBundleIdentifier: huge)))
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(envelope, inFlight: 0) else {
            Issue.record("expected a refusal"); return
        }
        #expect(error == .invalidRequest(.oversized))
    }

    /// The header is what makes the version knowable at the cap: a skewed peer's envelope
    /// refuses to decode, but the version it announced is still readable on its own.
    @Test func theVersionHeaderDecodesFromAnEnvelopeThatDoesNot() throws {
        let older = RuntimeProtocolVersion(RuntimeProtocolVersion.current.rawValue - 1)
        let encoded = try JSONEncoder().encode(RuntimeRequestEnvelope(protocolVersion: older, request: .runtimeVersion))
        #expect(try JSONDecoder().decode(RuntimeRequestEnvelope.Header.self, from: encoded).protocolVersion == older)
        #expect(throws: RuntimeRequestEnvelope.ProtocolMismatch.self) {
            try JSONDecoder().decode(RuntimeRequestEnvelope.self, from: encoded)
        }
    }

    @Test func aMismatchClosesTheSessionAfterItsReply() {
        guard case .replyAndClose(.failed(_, let error)) = RuntimeDispatcher.mismatch(.protocolMismatch(client: 99, service: 1)) else {
            Issue.record("expected replyAndClose"); return
        }
        #expect(error == .protocolMismatch(client: 99, service: 1))
    }
}
