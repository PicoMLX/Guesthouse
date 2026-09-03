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
        #expect(RuntimeDispatcher.admit(inFlight: 0) == nil)
        guard case .reply(.failed(_, let error))? = RuntimeDispatcher.admit(inFlight: RuntimeDispatcher.maximumInFlightRequestsPerSession) else {
            Issue.record("expected a refusal at the cap"); return
        }
        #expect(error == .invalidRequest(.tooManyInFlight))
    }

    @Test func anOversizedEnvelopeIsRefusedBeforeItIsDispatched() {
        let huge = String(repeating: "a", count: RequestValidator.maximumEncodedSize)
        let envelope = RuntimeRequestEnvelope(request: .importXcode(EnvironmentID(), FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app", expectedBundleIdentifier: huge)))
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(envelope, inFlight: 0) else {
            Issue.record("expected a refusal"); return
        }
        #expect(error == .invalidRequest(.oversized))
    }

    @Test func aMismatchClosesTheSessionAfterItsReply() {
        guard case .replyAndClose(.failed(_, let error)) = RuntimeDispatcher.mismatch(.protocolMismatch(client: 99, service: 1)) else {
            Issue.record("expected replyAndClose"); return
        }
        #expect(error == .protocolMismatch(client: 99, service: 1))
    }
}
