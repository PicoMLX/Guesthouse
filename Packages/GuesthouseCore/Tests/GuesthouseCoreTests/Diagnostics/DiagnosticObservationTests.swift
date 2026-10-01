import Foundation
import GuesthouseCore
import Testing

struct DiagnosticObservationTests {
    @Test(arguments: [DiagnosticEvent.ObservationFailure.connectionLost,
                      .metadataUnavailable(.loading), .metadataUnavailable(.repairRequired),
                      .metadataUnavailable(.incompatible), .metadataUnavailable(.unavailable)])
    func observationsHaveClosedExplanationsAndExplicitExportIdentity(_ failure: DiagnosticEvent.ObservationFailure) throws {
        let event = DiagnosticEvent(operation: .inspectEnvironment, outcome: .observationFailed(failure),
            operationID: UUID(), origin: .appObservation)
        #expect(event.message == "Inspect development Mac: " + failure.message && event.recoveryMessage == failure.recoveryMessage)
        #expect(!failure.recoveryMessage.isEmpty && !event.isRuntimeEvent && event.exitStatus == nil)
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
        var log = DiagnosticLog(); log.append(event)
        #expect(log.text.contains("[App observation \(event.operationID)]"))
        let exported = try #require(JSONSerialization.jsonObject(with: log.jsonData()) as? [String: Any])
        #expect(exported["schemaVersion"] as? Int == 4)
    }

    @Test(arguments: [false, true])
    func observationsCannotBeClaimedAsRuntimeWireEvents(claimedRuntimeOrigin: Bool) throws {
        let event = DiagnosticEvent(operation: .inspectEnvironment, outcome: .observationFailed(.connectionLost),
            operationID: UUID(), origin: claimedRuntimeOrigin ? .runtimeOperation : .appObservation)
        let envelope = RuntimeEventEnvelope(event: .diagnostic(event))
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try envelope.encoded() }
        let forged = try JSONEncoder().encode(envelope)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try RuntimeEventEnvelope.decode(forged) }
    }

    @Test func unknownOriginsAndExtraPrivateFieldsAreNotExported() throws {
        let event = DiagnosticEvent(operation: .inspectEnvironment, outcome: .observationFailed(.connectionLost),
            operationID: UUID(), origin: .appObservation)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        object["transportError"] = "synthetic-private-marker"
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object))
        var actual = DiagnosticLog(); actual.append(decoded, recordedAt: Date(timeIntervalSince1970: 0))
        var control = DiagnosticLog(); control.append(event, recordedAt: Date(timeIntervalSince1970: 0))
        #expect(try actual.jsonData() == control.jsonData() && actual.text == control.text)
        object["origin"] = "synthetic-private-marker"
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func appOriginCannotAttachAnOrdinaryFailureToARuntimeEvent() throws {
        let event = DiagnosticEvent(operation: .inspectEnvironment, outcome: .operationFailed(.runtimeMissing),
            operationID: UUID(), origin: .appObservation)
        let envelope = RuntimeEventEnvelope(event: .diagnostic(event))
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try envelope.encoded() }
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            try RuntimeEventEnvelope.decode(JSONEncoder().encode(envelope))
        }
    }
}
