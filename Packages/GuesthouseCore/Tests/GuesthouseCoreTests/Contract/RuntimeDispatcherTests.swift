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
        #expect(error == .invalidRequest(.oversized))
    }

    @Test func undecodableMessagesAreMalformed() {
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.undecodable() else { Issue.record("expected reply"); return }
        #expect(error == .invalidRequest(.malformed))
    }
}
