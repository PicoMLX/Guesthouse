import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeProbeWireTests {
    static let refused = RuntimeProbeReport(failure: .runtimeMissing, diagnostics: [])
    static let complete = RuntimeProbeReport(advertisements: .init(version: SemanticVersion([0, 6, 1]),
        unattendedTahoeAdvertised: false, createRunAttachStorageAdvertised: false,
        detachedRunAdvertised: false, nativeAttachAdvertised: false), diagnostics: (0..<4).flatMap { _ in
            let id = UUID()
            return [DiagnosticEvent(operation: .verifyRuntime, outcome: .started, operationID: id),
                    DiagnosticEvent(operation: .verifyRuntime, outcome: .succeeded, operationID: id)]
        })

    @Test func explicitRequestDiscardsCallerExecutionAndStorageHints() throws {
        let input: [String: Any] = ["protocolVersion": RuntimeProtocolVersion.current.rawValue,
            "request": ["probeRuntime": ["executable": "private-marker", "arguments": ["private-marker"],
                "storage": "private-marker", "provider": "private-marker", "operationID": UUID().uuidString]]]
        let envelope = try RequestValidator.decode(JSONSerialization.data(withJSONObject: input))
        #expect(envelope.request == .probeRuntime)
        #expect(envelope.request.caseName == "probeRuntime")
        let canonical = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope.request)) as? [String: [String: String]])
        #expect(canonical == ["probeRuntime": [:]])
        #expect(RuntimeDispatcher.decide(try JSONEncoder().encode(envelope), inFlight: 0) == .dispatch(.probeRuntime))
        guard case .reply(.failed(_, .invalidRequest(.tooManyInFlight))) =
            RuntimeDispatcher.decide(try JSONEncoder().encode(envelope), inFlight: 8) else {
            Issue.record("Probe bypassed the existing session cap"); return
        }
    }

    @Test(arguments: [refused, complete])
    func reportUsesTheMandatoryEnvelopeWithoutBecomingAnOperation(report: RuntimeProbeReport) throws {
        let envelope = RuntimeEventEnvelope(event: .runtimeProbe(report))
        #expect(try RuntimeEventEnvelope.decode(envelope.encoded()) == envelope)
        #expect(envelope.event.caseName == "runtimeProbe")
        #expect(envelope.event.diagnosticEvent == nil)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            try RuntimeEventEnvelope.decode(JSONEncoder().encode(envelope.event))
        }
    }

    @Test func nestedReportValidationAndForeignHeaderPrecedenceRemainMandatory() throws {
        let invalid = RuntimeProbeReport(failure: .timedOut, diagnostics: [])
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            try RuntimeEventEnvelope(event: .runtimeProbe(invalid)).encoded()
        }
        var report = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.refused)) as? [String: Any])
        report["failure"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RuntimeProbeFailure.timedOut))
        var input: [String: Any] = ["protocolVersion": RuntimeProtocolVersion.current.rawValue,
                                  "event": ["runtimeProbe": ["_0": report]]]
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            try RuntimeEventEnvelope.decode(JSONSerialization.data(withJSONObject: input))
        }
        input["protocolVersion"] = 20
        #expect(throws: GuesthouseError.protocolMismatch(client: 21, service: 20)) {
            try RuntimeEventEnvelope.decode(JSONSerialization.data(withJSONObject: input))
        }
    }

    @Test func unknownReportAttachmentsNeverReachTheCanonicalReply() throws {
        var report = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.refused)) as? [String: Any])
        report["stdout"] = "private-marker"
        report["path"] = "private-marker"
        let input: [String: Any] = ["protocolVersion": RuntimeProtocolVersion.current.rawValue,
                                  "event": ["runtimeProbe": ["_0": report]]]
        let envelope = try RuntimeEventEnvelope.decode(JSONSerialization.data(withJSONObject: input))
        #expect(envelope.event == .runtimeProbe(Self.refused))
        #expect(!String(decoding: try envelope.encoded(), as: UTF8.self).contains("private-marker"))
    }

    @Test func fakeBackendRefusesProbeWithoutInventingAReportOrAcceptance() async throws {
        let backend = FakeRuntimeBackend()
        var values: [RuntimeEvent] = []
        for try await value in backend.send(.probeRuntime) { values.append(value) }
        try #require(values.count == 1)
        guard case .failed(_, .invalidRequest(.unsupportedOperation)) = values[0] else {
            Issue.record("Fake probe invented execution evidence"); return
        }
        #expect(await backend.receivedRequests == [.probeRuntime])
    }

    @Test func reportRetainsTheTransportByteCeilingBeforeParsing() throws {
        var bytes = try RuntimeEventEnvelope(event: .runtimeProbe(Self.complete)).encoded()
        bytes.append(Data(repeating: 32, count: RuntimeEventEnvelope.maximumEncodedSize - bytes.count))
        #expect(try RuntimeEventEnvelope.decode(bytes).event == .runtimeProbe(Self.complete))
        bytes.append(0)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.oversized)) { try RuntimeEventEnvelope.decode(bytes) }
    }
}
