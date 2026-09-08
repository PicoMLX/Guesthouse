import Foundation
import GuesthouseCore
import Testing

struct DiagnosticLogTests {
    private static let operationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private static let timestamp = Date(timeIntervalSince1970: 0)

    @Test(arguments: DiagnosticFailure.allCases)
    func errorsRemainActionable(_ failure: DiagnosticFailure) throws {
        let event = DiagnosticEvent(operation: .connectSSH, outcome: .failed(failure),
                                    operationID: Self.operationID, exitStatus: 255)
        #expect(event.message == "Connect over SSH: " + failure.message + " Exit status: 255.")
        #expect(event.recoveryMessage == failure.recoveryMessage)
        #expect(!failure.recoveryMessage.isEmpty)
        #expect(failure.errorDescription == failure.message)
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test(arguments: DiagnosticEvent.Operation.allCases)
    func lifecycleMessages(_ operation: DiagnosticEvent.Operation) {
        let event = DiagnosticEvent(operation: operation, outcome: .started, operationID: Self.operationID)
        #expect(event.message == operation.title + ": Started.")
        #expect(event.recoveryMessage == nil)
    }

    @Test(arguments: [
        "syntheticOpaque", "Authorization: Bearer syntheticOpaque", "-----BEGIN PRIVATE KEY-----\nsyntheticOpaque",
        "Your code is\nsyntheticOpaque", #"{\"pass\u0077ord\":\"syntheticOpaque\"}"#,
        "\u{1B}[1DsyntheticOpaque"
    ])
    func untrustedExtraFieldsNeverReachMessagesOrExports(_ raw: String) throws {
        let expected = DiagnosticEvent(operation: .connectSSH, outcome: .failed(.connectionFailed),
                                       operationID: Self.operationID)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        for key in ["message", "stderr", "stdout", "errorDescription", "arguments", "environment"] {
            object[key] = raw
        }
        let event = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(event == expected)
        var actual = DiagnosticLog()
        var control = DiagnosticLog()
        actual.append(event, recordedAt: Self.timestamp)
        control.append(expected, recordedAt: Self.timestamp)
        #expect(actual.text == control.text)
        #expect(try actual.jsonData() == control.jsonData())
    }

    @Test(arguments: ["operation", "outcome", "operationID", "environmentID", "exitStatus"])
    func arbitraryTextInTypedFieldsIsRejected(_ field: String) throws {
        let event = DiagnosticEvent(operation: .checkTools, outcome: .succeeded, operationID: Self.operationID)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        object[field] = "syntheticOpaque"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DiagnosticEvent.self, from: data) }
    }

    @Test func boundedHistoryPreservesTheNewestEvents() {
        var log = DiagnosticLog(capacity: 2)
        for status: Int32 in [1, 2, 3] {
            log.append(DiagnosticEvent(operation: .checkTools, outcome: .failed(.processFailed),
                                       operationID: Self.operationID, exitStatus: status), recordedAt: Self.timestamp)
        }
        #expect(log.records.map(\.event.exitStatus) == [2, 3])
        #expect(log.discardedCount == 1)
        log.removeAll()
        #expect(log.records.isEmpty)
        #expect(log.discardedCount == 0)
    }

    @Test(arguments: [-1, 0, 1, 256, Int.max])
    func capacityIsBounded(_ capacity: Int) {
        var log = DiagnosticLog(capacity: capacity)
        log.append(DiagnosticEvent(operation: .checkTools, outcome: .started, operationID: Self.operationID))
        #expect(log.capacity == min(max(capacity, 0), DiagnosticLog.maximumCapacity))
        #expect(log.records.count == (capacity > 0 ? 1 : 0))
        #expect(log.discardedCount == (capacity > 0 ? 0 : 1))
    }

    @Test func cancellationDoesNotClaimAStoppedProcess() {
        let event = DiagnosticEvent(operation: .stopEnvironment, outcome: .cancellationRequested,
                                    operationID: Self.operationID)
        #expect(event.message == "Stop development Mac: Cancellation requested; completion is not yet confirmed.")
        #expect(event.recoveryMessage == "Wait for the operation to stop, then inspect its outcome.")
    }

    @Test func confirmedCancellationHasATerminalExplanation() throws {
        let event = DiagnosticEvent(operation: .deleteEnvironment, outcome: .canceled, operationID: Self.operationID)
        #expect(event.message == "Delete development Mac: Cancellation confirmed; partial changes may remain.")
        #expect(event.recoveryMessage == "Inspect any partial changes before starting another operation.")
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test(arguments: [
        (DiagnosticEvent.Operation.preflight, "Run Check this Mac again and review the host requirements in Settings."),
        (.verifyRuntime, "Open Repair and inspect the runtime installation before trying again."),
        (.exportDiagnostics, "Check the selected export location and available disk space before exporting again."),
        (.githubSignIn, "Open Accounts and check sign-in status before trying again.")
    ], [DiagnosticFailure.timedOut, .processFailed, .outcomeUnknown])
    func recoveryFitsTheOperation(_ example: (DiagnosticEvent.Operation, String), _ failure: DiagnosticFailure) {
        let event = DiagnosticEvent(operation: example.0, outcome: .failed(failure), operationID: Self.operationID)
        #expect(event.recoveryMessage == example.1)
    }
}
