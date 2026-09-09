import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeDispatcherTests {
    /// Migrated #110 scenarios now pass original bytes, never a re-encoded decoded object.
    @Test func validRequestIsDispatchedAtTheLastAvailableSlot() throws {
        let data = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .runtimeVersion))
        #expect(RuntimeDispatcher.decide(data, inFlight: 7) == .dispatch(.runtimeVersion))
    }

    @Test(arguments: [0, 8])
    func foreignVersionWinsOverAnUnknownPayload(inFlight: Int) throws {
        let version = RuntimeProtocolVersion.current.rawValue + 1
        let data = Data("{\"protocolVersion\":\(version),\"request\":{\"futureOperation\":{}}}".utf8)
        guard case .replyAndClose(.failed(_, let error)) = RuntimeDispatcher.decide(data, inFlight: inFlight) else {
            Issue.record("expected mismatch and close"); return
        }
        #expect(error == .protocolMismatch(client: version, service: RuntimeProtocolVersion.current.rawValue))
    }

    @Test func invalidOptionsAreRejectedWithoutClosing() throws {
        let envelope = RuntimeRequestEnvelope(request: .startEnvironment(EnvironmentID(), StartOptions(ipWait: .seconds(10_000))))
        let data = try JSONEncoder().encode(envelope)
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(data, inFlight: 0) else {
            Issue.record("expected request rejection"); return
        }
        #expect(error == .invalidRequest(.malformed))
    }

    @Test(arguments: [8, 9, Int.max])
    func theCapRejectsBeforeInterpretingPayload(inFlight: Int) {
        let data = Data("{\"protocolVersion\":\(RuntimeProtocolVersion.current.rawValue),\"request\":\"not-a-request\"}".utf8)
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(data, inFlight: inFlight) else {
            Issue.record("expected over-cap rejection"); return
        }
        #expect(error == .invalidRequest(.tooManyInFlight))
        #expect(error.recoveryActions == [.inspectState, .cancel])
        #expect(!error.isRetryable)
    }

    @Test func theHeaderIsReadOnlyAtTheCap() {
        var reads = 0
        #expect(RuntimeDispatcher.admit(inFlight: 7, clientVersion: { reads += 1; return .current }) == nil)
        #expect(reads == 0)
        _ = RuntimeDispatcher.admit(inFlight: 8, clientVersion: { reads += 1; return .current })
        #expect(reads == 1)
    }

    @Test func anUnreadableHeaderAndInvalidAccountingAreMalformed() {
        guard case .reply(.failed(_, let missing))? = RuntimeDispatcher.admit(inFlight: 8, clientVersion: { nil }) else {
            Issue.record("expected malformed header rejection"); return
        }
        #expect(missing == .invalidRequest(.malformed))
        var reads = 0
        guard case .reply(.failed(_, let invalid))? = RuntimeDispatcher.admit(inFlight: -1, clientVersion: { reads += 1; return .current }) else {
            Issue.record("expected invalid accounting rejection"); return
        }
        #expect(invalid == .invalidRequest(.malformed))
        #expect(reads == 0)
    }

    @Test(arguments: ["", "{}", "{\"protocolVersion\":\"private-marker\"}"])
    func malformedInputHasOnlyFixedErrors(input: String) {
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(Data(input.utf8), inFlight: 0) else {
            Issue.record("expected malformed request"); return
        }
        #expect(error == .invalidRequest(.malformed))
        #expect(error.userMessage == "The request is incomplete or has an invalid format.")
    }

    @Test func ignoredFieldsCannotDisappearBeforeTheSizeCheck() throws {
        let payload = "{\"protocolVersion\":\(RuntimeProtocolVersion.current.rawValue),\"request\":{\"runtimeVersion\":{}},\"ignored\":\"\(String(repeating: "x", count: 65_537))\"}"
        let data = Data(payload.utf8)
        // Reproduces the old loss: bare decoding/reencoding removes the oversized extra field.
        let decoded = try JSONDecoder().decode(RuntimeRequestEnvelope.self, from: data)
        #expect(try JSONEncoder().encode(decoded).count < RequestValidator.maximumEncodedSize)
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(data, inFlight: 0) else {
            Issue.record("expected original-byte size rejection"); return
        }
        #expect(error == .invalidRequest(.oversized))
    }

    @Test func exactByteBoundaryAndOversizeBeforeHeaderParsing() throws {
        var data = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .runtimeVersion))
        data.append(Data(repeating: 32, count: RequestValidator.maximumEncodedSize - data.count))
        #expect(RuntimeDispatcher.decide(data, inFlight: 0) == .dispatch(.runtimeVersion))
        data.append(32)
        guard case .reply(.failed(_, let error)) = RuntimeDispatcher.decide(data, inFlight: 8) else {
            Issue.record("expected size rejection before header parsing"); return
        }
        #expect(error == .invalidRequest(.oversized))
    }

    @Test func refusalOverridesOnlyDispatch() {
        let refusal = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        let dispatch = RuntimeDispatcher.Decision.dispatch(.runtimeVersion)
        let answer = RuntimeDispatcher.undecodable()
        #expect(RuntimeDispatcher.refused(refusal) == .reply(refusal))
        #expect(RuntimeDispatcher.honoring(refusal, dispatch) == .reply(refusal))
        #expect(RuntimeDispatcher.honoring(nil, dispatch) == dispatch)
        #expect(RuntimeDispatcher.honoring(refusal, answer) == answer)
    }

    @Test func unrefusedSessionNeverClosesAndSingleRefusedReplyDoes() {
        var lifetime = RuntimeDispatcher.SessionLifetime()
        let firstCount = lifetime.began()
        let firstCloses = lifetime.finished()
        #expect(firstCount == 0)
        #expect(!firstCloses)
        #expect(lifetime.refusal == nil)
        let secondCount = lifetime.began()
        #expect(secondCount == 0)
        lifetime.refuse(.failed(OperationID(), .unauthorizedCaller))
        let secondCloses = lifetime.finished()
        #expect(secondCloses)
        #expect(lifetime.isClosing)
        let afterClose = lifetime.began()
        #expect(afterClose == nil)
        #expect(lifetime.inFlight == 0)
    }

    @Test func capErrorRoundTripsWithoutRawMetadata() throws {
        let event = RuntimeEvent.failed(OperationID(), .invalidRequest(.tooManyInFlight))
        let envelope = RuntimeEventEnvelope(event: event)
        #expect(try RuntimeEventEnvelope.decode(envelope.encoded()) == envelope)
    }
}
