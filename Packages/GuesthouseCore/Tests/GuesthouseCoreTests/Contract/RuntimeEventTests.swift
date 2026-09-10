import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeEventTests {
    static let operation = OperationID()
    static let diagnostic = DiagnosticEvent(operation: .startEnvironment, outcome: .started, operationID: operation.uuid)
    static let events: [RuntimeEvent] = [
        .runtimeVersion(RuntimeVersionInfo(serviceVersion: "0.1.0", serviceBuild: "12")),
        .hostPreflight(PreflightCheck.run(snapshot: HostProbeSnapshot())),
        .accepted(operation), .progress(operation, ProgressPhase(kind: .copying, fraction: 0.5)),
        .diagnostic(diagnostic), .status(RuntimeStatusTests.status()),
        .completed(operation), .failed(operation, .operationOutcomeUnknown(operation))
    ]

    @Test(arguments: events)
    func namedEventRoundTripsUseMandatoryEnvelope(event: RuntimeEvent) throws {
        let envelope = RuntimeEventEnvelope(event: event)
        let data = try envelope.encoded()
        #expect(try RuntimeEventEnvelope.decode(data) == envelope)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["protocolVersion", "event"])
        #expect(object["protocolVersion"] as? Int == 13)
    }

    @Test(arguments: events)
    func bareEventsHaveNoLegacyFallback(event: RuntimeEvent) throws {
        let data = try JSONEncoder().encode(event)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try RuntimeEventEnvelope.decode(data) }
    }

    @Test(arguments: [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, Int.max])
    func foreignHeaderPrecedesUnknownEvent(version: Int) {
        let data = Data("{\"event\":{\"futureReply\":{}},\"protocolVersion\":\(version)}".utf8)
        #expect(throws: GuesthouseError.protocolMismatch(client: 13, service: version)) {
            try RuntimeEventEnvelope.decode(data)
        }
    }

    @Test func directDecoderChecksVersionBeforeAbsentPayload() throws {
        let data = Data(#"{"protocolVersion":7}"#.utf8)
        let mismatch = try #require(throws: RuntimeEventEnvelope.ProtocolMismatch.self) {
            try JSONDecoder().decode(RuntimeEventEnvelope.self, from: data)
        }
        #expect(mismatch.error == .protocolMismatch(client: 13, service: 7))
    }

    @Test func contradictoryNestedVersionIsMalformedOnBothPaths() throws {
        let envelope = RuntimeEventEnvelope(event: .runtimeVersion(RuntimeVersionInfo(
            serviceVersion: "0.1", serviceBuild: "12", protocolVersion: RuntimeProtocolVersion(7))))
        let forged = try JSONEncoder().encode(envelope)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try RuntimeEventEnvelope.decode(forged) }
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try envelope.encoded() }
        let foreign = RuntimeEventEnvelope(protocolVersion: RuntimeProtocolVersion(7), event: Self.events[0])
        #expect(throws: GuesthouseError.protocolMismatch(client: 13, service: 7)) { try foreign.encoded() }
        let foreignBytes = try JSONEncoder().encode(foreign)
        #expect(throws: GuesthouseError.protocolMismatch(client: 13, service: 7)) { try RuntimeEventEnvelope.decode(foreignBytes) }
    }

    @Test(arguments: ["{}", "null", "not-json", #"{"protocolVersion":13}"#,
                      #"{"protocolVersion":"13","event":{}}"#,
                      #"{"protocolVersion":13,"event":{"log":{"_0":null,"_1":"private-marker"}}}"#,
                      #"{"protocolVersion":13,"event":{"futureReply":{}}}"#])
    func malformedOrRawLogRepliesAreFixedErrors(json: String) {
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            try RuntimeEventEnvelope.decode(Data(json.utf8))
        }
    }

    @Test func responseSizeIsAdmittedBeforeJSONParsing() throws {
        var data = try RuntimeEventEnvelope(event: .completed(Self.operation)).encoded()
        data.append(Data(repeating: 32, count: 65_536 - data.count))
        #expect(try RuntimeEventEnvelope.decode(data).event == .completed(Self.operation))
        data.append(0)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.oversized)) { try RuntimeEventEnvelope.decode(data) }
    }

    @Test func underlyingEncoderFailureDoesNotEscape() {
        let status = EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped, readiness: .checking,
                                       reconciledAt: Date(timeIntervalSince1970: .infinity))
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            try RuntimeEventEnvelope(event: .status(status)).encoded()
        }
    }

    @Test func onlyExplicitDiagnosticsEnterTheLog() throws {
        var observed = ObservedTuple(CompatibilityTupleTests.tuple())
        observed.codexCLIPath = "/opt/private-marker/codex"
        let status = RuntimeEvent.status(RuntimeStatusTests.status(observed))
        let version = RuntimeEvent.runtimeVersion(RuntimeVersionInfo(serviceVersion: "1-private-marker", serviceBuild: "12"))
        let messages = [status, version, .diagnostic(Self.diagnostic)]
        var log = DiagnosticLog()
        for message in messages {
            let decoded = try RuntimeEventEnvelope.decode(RuntimeEventEnvelope(event: message).encoded())
            if let event = decoded.event.diagnosticEvent { log.append(event) }
        }
        #expect(log.records.count == 1)
        #expect(log.records.first?.event == Self.diagnostic)
        #expect(status.diagnosticEvent == nil)
        #expect(version.diagnosticEvent == nil)
        #expect(!log.text.contains("private-marker"))
        #expect(!String(decoding: try log.jsonData(), as: UTF8.self).contains("private-marker"))
    }

    @Test func unknownDiagnosticAttachmentsAreNotReexported() throws {
        var event = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.diagnostic)) as? [String: Any])
        event["message"] = "private-marker"
        event["stderr"] = "private-marker"
        let object: [String: Any] = ["protocolVersion": 13, "event": ["diagnostic": ["_0": event]]]
        let decoded = try RuntimeEventEnvelope.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.event.diagnosticEvent == Self.diagnostic)
        #expect(!String(decoding: try decoded.encoded(), as: UTF8.self).contains("private-marker"))
    }

    @Test(arguments: [(GuesthouseError.InvalidRuntimeReplyReason.malformed,
                       "Guesthouse received an invalid reply from its runtime service. An in-flight operation may still be running."),
                      (.oversized, "The runtime service's reply exceeds Guesthouse's supported size limit. An in-flight operation may still be running.")])
    func replyFailuresHaveSpecificSafeRecovery(reason: GuesthouseError.InvalidRuntimeReplyReason, message: String) throws {
        let error = GuesthouseError.invalidRuntimeReply(reason)
        #expect(error.userMessage == message)
        #expect(error.category == .ipc)
        #expect(error.recoveryActions == [.inspectState, .updateApp, .cancel])
        #expect(!error.isRetryable)
        let event = RuntimeEvent.failed(Self.operation, error)
        #expect(try RuntimeEventEnvelope.decode(RuntimeEventEnvelope(event: event).encoded()).event == event)
        let diagnostic = DiagnosticEvent(operation: .startEnvironment, outcome: .init(error: error), operationID: Self.operation.uuid)
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(diagnostic)) == diagnostic)
    }

    @Test(arguments: VMProvider.allCases)
    func providerIdentityIsExplicitAndRoundTrips(provider: VMProvider) throws {
        let runtime = RuntimeIdentityInfo(provider: provider, version: "1.2.3", verified: true)
        let info = RuntimeVersionInfo(serviceVersion: "0.1", serviceBuild: "12", runtime: runtime)
        let envelope = RuntimeEventEnvelope(event: .runtimeVersion(info))
        #expect(try RuntimeEventEnvelope.decode(envelope.encoded()) == envelope)
        #expect(runtime.verified)
        #expect(runtime.problem == nil)
    }

    @Test(arguments: ["", "private marker", "0.1\u{1B}[31m", String(repeating: "1", count: 257)])
    func malformedMetadataBecomesUnknownWithoutInventingIdentity(value: String) throws {
        let raw: [String: Any] = ["serviceVersion": value, "serviceBuild": value, "protocolVersion": 13,
                                  "runtime": ["provider": "lume", "version": value, "verified": true]]
        let info = try JSONDecoder().decode(RuntimeVersionInfo.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(info.serviceVersion == nil)
        #expect(info.serviceBuild == nil)
        #expect(info.runtime?.version == nil)
        #expect(info.runtime?.verified == false)
        #expect(info.runtime?.problem == .runtimeIncompatible)
        #expect(try JSONDecoder().decode(RuntimeVersionInfo.self, from: JSONEncoder().encode(info)) == info)
    }

    @Test func missingMetadataAndProblemsNeverImplyVerified() throws {
        let unknown = RuntimeIdentityInfo(provider: .lume, version: nil, verified: true)
        #expect(!unknown.verified)
        #expect(unknown.problem == .runtimeIncompatible)
        let failed = RuntimeIdentityInfo(provider: .lume, version: "0.5.3", verified: true, problem: .runtimeMissing)
        #expect(!failed.verified)
        #expect(failed.problem == .runtimeMissing)
        let missing = try JSONDecoder().decode(RuntimeVersionInfo.self, from: Data(#"{"protocolVersion":13}"#.utf8))
        #expect(missing.runtime == nil)
        #expect(missing.serviceVersion == nil)
        #expect(missing.serviceBuild == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuntimeIdentityInfo.self, from: Data(#"{"provider":"other","version":"1","verified":true}"#.utf8))
        }
    }

    @Test func validMetadataAtTheByteLimitIsNotTruncated() throws {
        let version = "1" + String(repeating: "a", count: 255)
        let info = RuntimeVersionInfo(serviceVersion: version, serviceBuild: version,
                                      runtime: RuntimeIdentityInfo(provider: .lume, version: version, verified: false))
        #expect(info.serviceVersion == version)
        #expect(info.runtime?.version == version)
        #expect(try JSONDecoder().decode(RuntimeVersionInfo.self, from: JSONEncoder().encode(info)) == info)
    }
}
