import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeProbeReportTests {
    static let advertisements = RuntimeProbeAdvertisement(version: SemanticVersion([0, 5, 3]),
        unattendedTahoeAdvertised: true, createRunAttachStorageAdvertised: true,
        detachedRunAdvertised: true, nativeAttachAdvertised: true)
    static func pair(_ outcome: DiagnosticEvent.Outcome = .succeeded, id: UUID = UUID()) -> [DiagnosticEvent] {
        [.init(operation: .verifyRuntime, outcome: .started, operationID: id),
         .init(operation: .verifyRuntime, outcome: outcome, operationID: id)]
    }
    static func successes(_ count: Int = 4) -> [DiagnosticEvent] { (0..<count).flatMap { _ in pair() } }

    @Test func boundedCompleteReportRoundTripsWithoutRawOrReadinessFields() throws {
        let report = RuntimeProbeReport(advertisements: Self.advertisements, diagnostics: Self.successes())
        let bytes = try JSONEncoder().encode(report)
        #expect(bytes.count < RuntimeEventEnvelope.maximumEncodedSize)
        #expect(try JSONDecoder().decode(RuntimeProbeReport.self, from: bytes) == report)
        let value = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(value.keys) == ["advertisements", "diagnostics"])
        let options = try #require(value["advertisements"] as? [String: Any])
        #expect(Set(options.keys) == ["version", "unattendedTahoeAdvertised", "createRunAttachStorageAdvertised",
                                     "detachedRunAdvertised", "nativeAttachAdvertised"])
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func refusalAfterRealPriorSuccessesNeedsNoInventedFailureID(_ completed: Int) throws {
        let report = RuntimeProbeReport(failure: .outcomeUnknown, diagnostics: Self.successes(completed))
        #expect(report.isValid)
        #expect(try JSONDecoder().decode(RuntimeProbeReport.self, from: JSONEncoder().encode(report)) == report)
        if completed == 0 { #expect(report.diagnostics.isEmpty) }
    }

    @Test(arguments: [0, 1, 2, 3])
    func terminalFailureMustMatchItsFinalActualStartedPair(_ completed: Int) throws {
        let failure = RuntimeProbeFailure.processFailed(exitStatus: 23)
        let report = RuntimeProbeReport(failure: failure,
            diagnostics: Self.successes(completed) + Self.pair(failure.diagnosticOutcome))
        #expect(try JSONDecoder().decode(RuntimeProbeReport.self, from: JSONEncoder().encode(report)) == report)
    }

    @Test(arguments: ["missing", "both", "short", "long", "unpaired", "foreign", "environment", "operation", "reused", "earlyFailure", "wrongFailure", "confirmedCancel"])
    func malformedTraceCannotBeEncodedOrDecoded(_ defect: String) throws {
        var events = Self.successes(), advertisements: RuntimeProbeAdvertisement? = Self.advertisements
        var failure: RuntimeProbeFailure?
        switch defect {
        case "missing": advertisements = nil
        case "both": failure = .outcomeUnknown
        case "short": events = Self.successes(3)
        case "long": events = Self.successes(5)
        case "unpaired": events.removeLast()
        case "foreign": events[1] = .init(operation: .verifyRuntime, outcome: .succeeded, operationID: UUID())
        case "environment": events[0] = .init(operation: .verifyRuntime, outcome: .started, operationID: events[0].operationID, environmentID: EnvironmentID())
        case "operation": events[0] = .init(operation: .startEnvironment, outcome: .started, operationID: events[0].operationID)
        case "reused": events[2...3] = ArraySlice(Self.pair(id: events[0].operationID))
        case "earlyFailure": advertisements = nil; failure = .outcomeUnknown; events = Self.pair(failure!.diagnosticOutcome) + Self.successes(1)
        case "wrongFailure": advertisements = nil; failure = .timedOut; events = Self.pair(.failed(.outcomeUnknown))
        case "confirmedCancel": advertisements = nil; failure = .outcomeUnknown; events = Self.pair(.canceled)
        default: Issue.record("Unknown fixture defect")
        }
        let report = RuntimeProbeReport(advertisements: advertisements, failure: failure, diagnostics: events)
        #expect(!report.isValid)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { _ = try JSONEncoder().encode(report) }
        // Build untrusted bytes without going through the report's guarded encoder.
        var object: [String: Any] = ["diagnostics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))]
        if let advertisements { object["advertisements"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(advertisements)) }
        if let failure { object["failure"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(failure)) }
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            _ = try JSONDecoder().decode(RuntimeProbeReport.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test(arguments: [Int32.min, -1, 0, 256, Int32.max])
    func impossibleProcessStatusCannotBecomeAValidReply(_ status: Int32) {
        let failure = RuntimeProbeFailure.processFailed(exitStatus: status)
        #expect(!RuntimeProbeReport(failure: failure, diagnostics: Self.pair(failure.diagnosticOutcome)).isValid)
    }

    private static func expectMalformed(_ report: RuntimeProbeReport) throws {
        #expect(!report.isValid)
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { _ = try JSONEncoder().encode(report) }
        var object: [String: Any] = ["diagnostics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.diagnostics))]
        if let advertisements = report.advertisements { object["advertisements"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(advertisements)) }
        if let failure = report.failure { object["failure"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(failure)) }
        #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) {
            _ = try JSONDecoder().decode(RuntimeProbeReport.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test(arguments: [RuntimeProbeFailure.versionMismatch, .invalidResponse, .timedOut, .processFailed(exitStatus: 23)], [0, 1, 2, 3, 4])
    func launchedFailuresRequireTheirMatchingTerminalPair(_ failure: RuntimeProbeFailure, _ completed: Int) throws {
        try Self.expectMalformed(RuntimeProbeReport(failure: failure, diagnostics: Self.successes(completed)))
        if completed < 4 {
            let valid = RuntimeProbeReport(failure: failure, diagnostics: Self.successes(completed) + Self.pair(failure.diagnosticOutcome))
            #expect(try JSONDecoder().decode(RuntimeProbeReport.self, from: JSONEncoder().encode(valid)) == valid)
        }
    }

    @Test(arguments: [RuntimeProbeFailure.runtimeMissing, .verificationFailed], [0, 1, 2, 3, 4])
    func prelaunchFailuresOnlyRetainPriorSuccessfulPairs(_ failure: RuntimeProbeFailure, _ completed: Int) throws {
        let prior = Self.successes(completed), report = RuntimeProbeReport(failure: failure, diagnostics: prior)
        if completed == 4 { try Self.expectMalformed(report) }
        else {
            #expect(try JSONDecoder().decode(RuntimeProbeReport.self, from: JSONEncoder().encode(report)) == report)
            try Self.expectMalformed(RuntimeProbeReport(failure: failure, diagnostics: prior + Self.pair(failure.diagnosticOutcome)))
        }
    }

    @Test(arguments: [0, 1, 7, 8])
    func appObservationCannotBorrowRuntimeReportIdentity(_ position: Int) throws {
        var events = Self.successes()
        for index in events.indices where index == position || position == events.count {
            let event = events[index]
            events[index] = .init(operation: event.operation, outcome: event.outcome,
                operationID: event.operationID, origin: .appObservation)
        }
        try Self.expectMalformed(RuntimeProbeReport(advertisements: Self.advertisements, diagnostics: events))
    }

    @Test func unknownAttachmentsCannotReachReexportOrStructuredDiagnostics() throws {
        let report = RuntimeProbeReport(advertisements: Self.advertisements, diagnostics: Self.successes())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object["stderr"] = "private-marker"
        var events = try #require(object["diagnostics"] as? [[String: Any]])
        events[0]["message"] = "private-marker"; object["diagnostics"] = events
        let decoded = try JSONDecoder().decode(RuntimeProbeReport.self, from: JSONSerialization.data(withJSONObject: object))
        var log = DiagnosticLog()
        for event in decoded.diagnostics { log.append(event) }
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("private-marker"))
        let exported = String(decoding: try log.jsonData(), as: UTF8.self)
        #expect(!log.text.contains("private-marker") && !exported.contains("private-marker"))
    }
}
