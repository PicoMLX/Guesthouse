import Foundation
import Testing
@testable import GuesthouseCore

struct HostPreflightWireTests {
    static let blocked = PreflightCheck.run(snapshot: HostProbeSnapshot(), now: Date(timeIntervalSince1970: 0))
    static let ready = PreflightCheck.run(snapshot: HostProbeSnapshot(
        cpuArchitecture: .appleSilicon, operatingSystemVersion: SemanticVersion([99]),
        physicalMemoryBytes: .max, powerSource: .externalPower, disk: .available(bytes: .max),
        codexDesktop: .installed(version: nil, build: nil)
    ), now: Date(timeIntervalSince1970: 0))

    @Test func queryCarriesNoCallerSelectedPathPolicyOrIdentity() throws {
        let input = Data(#"{"protocolVersion":13,"request":{"hostPreflight":{"path":"private-marker","volumeUUID":"private-marker","policy":"private-marker"}}}"#.utf8)
        let envelope = try RequestValidator.decode(input)
        #expect(envelope.request == .hostPreflight)
        #expect(envelope.request.caseName == "hostPreflight")
        let encoded = try JSONEncoder().encode(envelope.request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: [String: String]])
        #expect(object == ["hostPreflight": [:]])
    }

    @Test(arguments: [blocked, ready])
    func completeReportsRoundTripWithoutBecomingDiagnostics(report: PreflightReport) throws {
        #expect(report.isComplete)
        #expect(Self.ready.canProceed)
        #expect(!Self.blocked.canProceed)
        let envelope = RuntimeEventEnvelope(event: .hostPreflight(report))
        #expect(try RuntimeEventEnvelope.decode(envelope.encoded()) == envelope)
        #expect(envelope.event.caseName == "hostPreflight")
        #expect(envelope.event.diagnosticEvent == nil)
    }

    @Test(arguments: [
        [PreflightResult](), [.architectureUnknown],
        Array(blocked.results.dropLast()),
        Array(repeating: .architectureUnknown, count: 5),
        blocked.results + [.architectureUnknown],
    ])
    func incompleteOrDuplicatedReportsAreRefusedOnBothWirePaths(results: [PreflightResult]) throws {
        let report = PreflightReport(results: results, storage: Self.blocked.storage,
                                    powerSource: .unknown, checkedAt: Self.blocked.checkedAt)
        #expect(!report.isComplete)
        #expect(!report.canProceed)
        let envelope = RuntimeEventEnvelope(event: .hostPreflight(report))
        let forged = try JSONEncoder().encode(envelope)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try envelope.encoded() }
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try RuntimeEventEnvelope.decode(forged) }
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            try JSONDecoder().decode(RuntimeEventEnvelope.self, from: forged)
        }
    }

    @Test func reportAttachmentsAreNotForwardedOrExported() throws {
        var report = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.blocked)) as? [String: Any])
        report["path"] = "private-marker"
        report["error"] = ["Authorization": "private-marker"]
        let object: [String: Any] = ["protocolVersion": 13, "event": ["hostPreflight": ["_0": report]]]
        let decoded = try RuntimeEventEnvelope.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.event == .hostPreflight(Self.blocked))
        #expect(!String(decoding: try decoded.encoded(), as: UTF8.self).contains("private-marker"))
    }

    @Test func reportUsesTheExistingBoundBeforeParsing() throws {
        var bytes = try RuntimeEventEnvelope(event: .hostPreflight(Self.blocked)).encoded()
        bytes.append(Data(repeating: 32, count: 65_536 - bytes.count))
        #expect(try RuntimeEventEnvelope.decode(bytes).event == .hostPreflight(Self.blocked))
        bytes.append(0)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.oversized)) { try RuntimeEventEnvelope.decode(bytes) }
    }

    @Test func nonfiniteCompletionTimeCannotLeaveTheEnvelope() {
        let report = PreflightReport(results: Self.blocked.results, storage: Self.blocked.storage,
                                    powerSource: .unknown, checkedAt: Date(timeIntervalSince1970: .infinity))
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            try RuntimeEventEnvelope(event: .hostPreflight(report)).encoded()
        }
    }
}
