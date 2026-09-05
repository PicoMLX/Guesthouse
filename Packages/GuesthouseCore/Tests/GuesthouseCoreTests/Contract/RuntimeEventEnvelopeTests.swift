import Foundation
import GuesthouseCore
import Testing

struct RuntimeEventEnvelopeTests {
    @Test(arguments: [
        RuntimeEvent.runtimeVersion(RuntimeVersionInfo(serviceVersion: "0.1.0", serviceBuild: "12")),
        .accepted(OperationID()),
        .progress(OperationID(), ProgressPhase(kind: .copying, fraction: 0.5)),
        .log(OperationID(), RedactedLine(literal: "Started")),
        .log(nil, RedactedLine(literal: "Service launched")),
        .status(EnvironmentStatus(environmentID: EnvironmentID(), vm: .running, readiness: .ready)),
        .completed(OperationID()),
        .failed(OperationID(), .guestNotReachable(EnvironmentID()))
    ])
    func eventCasesRoundTrip(event: RuntimeEvent) throws {
        let envelope = RuntimeEventEnvelope(event: event)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RuntimeEventEnvelope.self, from: data)

        #expect(decoded == envelope)
        #expect(decoded.protocolVersion == .current)
    }

    @Test
    func wireKeysKeepVersionOutsideEvent() throws {
        let data = try JSONEncoder().encode(RuntimeEventEnvelope(event: .completed(OperationID())))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["protocolVersion", "event"])
        #expect(object["protocolVersion"] as? Int == RuntimeProtocolVersion.current.rawValue)
        #expect(object["event"] is [String: Any])
    }

    @Test(arguments: [0, 99])
    func foreignVersionRejectsUnknownEventBeforePayload(serviceVersion: Int) throws {
        // Put the event first in the encoded object: JSON key order must not affect validation.
        let json = #"{"event":{"futureReply":{}},"protocolVersion":\#(serviceVersion)}"#
        let mismatch = try #require(#expect(throws: RuntimeEventEnvelope.ProtocolMismatch.self) {
            try JSONDecoder().decode(RuntimeEventEnvelope.self, from: Data(json.utf8))
        })

        #expect(mismatch.service == RuntimeProtocolVersion(serviceVersion))
        #expect(mismatch.error == .protocolMismatch(
            client: RuntimeProtocolVersion.current.rawValue,
            service: serviceVersion
        ))
    }

    @Test
    func currentVersionUnknownEventIsMalformed() throws {
        let json = #"{"protocolVersion":\#(RuntimeProtocolVersion.current.rawValue),"event":{"futureReply":{}}}"#
        let error = try #require(#expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuntimeEventEnvelope.self, from: Data(json.utf8))
        })

        guard case .typeMismatch = error else {
            Issue.record("An unknown current-version event must be a malformed payload: \(error)")
            return
        }
    }

    @Test
    func missingVersionRefusesOtherwiseValidEvent() throws {
        let data = try JSONEncoder().encode(RuntimeEventEnvelope(event: .completed(OperationID())))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "protocolVersion")

        try expectMissingVersion(try JSONSerialization.data(withJSONObject: object))
    }

    @Test
    func bareEventHasNoUnversionedFallback() throws {
        try expectMissingVersion(try JSONEncoder().encode(RuntimeEvent.completed(OperationID())))
    }

    @Test
    func foreignHeaderWinsOverSupportedNestedVersion() throws {
        let envelope = RuntimeEventEnvelope(
            protocolVersion: RuntimeProtocolVersion(99),
            event: .runtimeVersion(RuntimeVersionInfo(serviceVersion: "0.1.0", serviceBuild: "12"))
        )
        let data = try JSONEncoder().encode(envelope)

        #expect(throws: RuntimeEventEnvelope.ProtocolMismatch(service: RuntimeProtocolVersion(99))) {
            try JSONDecoder().decode(RuntimeEventEnvelope.self, from: data)
        }
    }

    @Test
    func currentHeaderWithContradictoryNestedVersionIsMalformed() throws {
        let envelope = RuntimeEventEnvelope(event: .runtimeVersion(RuntimeVersionInfo(
            serviceVersion: "0.1.0",
            serviceBuild: "12",
            protocolVersion: RuntimeProtocolVersion(99)
        )))
        let data = try JSONEncoder().encode(envelope)
        let error = try #require(#expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuntimeEventEnvelope.self, from: data)
        })

        guard case .dataCorrupted(let context) = error else {
            Issue.record("Contradictory nested version information must be malformed: \(error)")
            return
        }
        #expect(context.codingPath.map(\.stringValue) == ["event"])
    }

    private func expectMissingVersion(_ data: Data) throws {
        let error = try #require(#expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuntimeEventEnvelope.self, from: data)
        })
        guard case .keyNotFound(let key, _) = error else {
            Issue.record("An unversioned reply must fail at its missing header: \(error)")
            return
        }
        #expect(key.stringValue == "protocolVersion")
    }
}
