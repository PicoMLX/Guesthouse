import Foundation
import GuesthouseCore
import Testing

struct DiagnosticLogTests {
    private static let operationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private static let timestamp = Date(timeIntervalSince1970: 0)

    @Test(arguments: DiagnosticFailure.allCases)
    func errorsRemainActionable(_ failure: DiagnosticFailure) throws {
        let event = DiagnosticEvent(operation: .connectSSH, outcome: .failed(failure, exitStatus: 255),
                                    operationID: Self.operationID)
        #expect(event.exitStatus == 255)
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

    @Test(arguments: ["operation", "outcome", "operationID", "environmentID"])
    func arbitraryTextInTypedFieldsIsRejected(_ field: String) throws {
        let event = DiagnosticEvent(operation: .checkTools, outcome: .succeeded, operationID: Self.operationID)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        object[field] = "syntheticOpaque"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DiagnosticEvent.self, from: data) }
    }

    @Test func arbitraryTextInFailureExitStatusIsRejected() throws {
        let data = Data(#"{"failed":{"_0":"processFailed","exitStatus":"syntheticOpaque"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DiagnosticEvent.Outcome.self, from: data) }
    }

    @Test(arguments: [
        DiagnosticEvent.Outcome.started, .succeeded, .pending, .waitingForUserAction,
        .cancellationRequested, .canceled
    ])
    func nonfailureOutcomesCannotCarryExitStatuses(_ outcome: DiagnosticEvent.Outcome) throws {
        let expected = DiagnosticEvent(operation: .checkTools, outcome: outcome, operationID: Self.operationID)
        #expect(expected.exitStatus == nil)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        object["exitStatus"] = 9
        let outcomeObject = try #require(object["outcome"] as? [String: Any])
        object["outcome"] = outcomeObject.mapValues { _ in ["exitStatus": 9] }
        let event = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(event == expected)
        #expect(event.exitStatus == nil)
        var log = DiagnosticLog()
        log.append(event, recordedAt: Self.timestamp)
        #expect(!log.text.contains("Exit status:"))
        #expect(!String(decoding: try log.jsonData(), as: UTF8.self).contains("exitStatus"))
    }

    @Test func boundedHistoryPreservesTheNewestEvents() {
        var log = DiagnosticLog(capacity: 2)
        for status: Int32 in [1, 2, 3] {
            log.append(DiagnosticEvent(operation: .checkTools, outcome: .failed(.processFailed, exitStatus: status),
                                       operationID: Self.operationID), recordedAt: Self.timestamp)
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

    @Test(arguments: [
        (DiagnosticEvent.Outcome.pending, "Queued; not started yet.", nil as String?),
        (.waitingForUserAction, "Waiting for user action; the operation has not failed.",
         "Complete the step shown by Guesthouse, then continue.")
    ])
    func nonterminalStagesHaveAnExplicitStatus(_ example: (DiagnosticEvent.Outcome, String, String?)) throws {
        let event = DiagnosticEvent(operation: .codexSignIn, outcome: example.0, operationID: Self.operationID)
        #expect(event.message == "Sign in to Codex: " + example.1)
        #expect(event.recoveryMessage == example.2)
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test func textExportIncludesStableUTCTimestamps() {
        var log = DiagnosticLog()
        let event = DiagnosticEvent(operation: .githubSignOut, outcome: .succeeded, operationID: Self.operationID)
        log.append(event, recordedAt: Self.timestamp)
        log.append(event, recordedAt: Date(timeIntervalSince1970: 0.123))
        log.append(event, recordedAt: Date(timeIntervalSince1970: 0.999))
        log.append(event, recordedAt: Date(timeIntervalSince1970: 1))
        let expected = [
            "Guesthouse structured diagnostics. Raw process and authentication output excluded.",
            "Older/omitted events: 0.",
            "1970-01-01T00:00:00.000Z [\(Self.operationID)] Sign out of GitHub: Succeeded.",
            "1970-01-01T00:00:00.123Z [\(Self.operationID)] Sign out of GitHub: Succeeded.",
            "1970-01-01T00:00:00.999Z [\(Self.operationID)] Sign out of GitHub: Succeeded.",
            "1970-01-01T00:00:01.000Z [\(Self.operationID)] Sign out of GitHub: Succeeded."
        ].joined(separator: "\n")
        #expect(log.text == expected)
    }

    @Test(arguments: [
        (DiagnosticEvent.Operation.downloadGuestImage, "Download macOS image: The downloaded artifact failed verification."),
        (.downloadRuntime, "Download runtime: The downloaded artifact failed verification.")
    ])
    func failedDownloadsHaveArtifactSpecificRecovery(_ example: (DiagnosticEvent.Operation, String)) throws {
        let event = DiagnosticEvent(operation: example.0, outcome: .failed(.verificationFailed), operationID: Self.operationID)
        #expect(event.message == example.1)
        #expect(event.recoveryMessage == "Use Repair to download a verified replacement from the trusted source. Preserve the existing development Mac and do not bypass verification.")
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test(arguments: [DiagnosticEvent.Operation.downloadGuestImage, .downloadRuntime],
          [DiagnosticFailure.timedOut, .processFailed, .outcomeUnknown])
    func incompleteDownloadsDoNotAssumeAnInstalledRuntime(_ operation: DiagnosticEvent.Operation, _ failure: DiagnosticFailure) {
        let event = DiagnosticEvent(operation: operation, outcome: .failed(failure), operationID: Self.operationID)
        #expect(event.recoveryMessage == "Open Repair and inspect the download's current state before resuming it.")
    }

    @Test(arguments: [
        (DiagnosticEvent.Operation.pairSSH, "Pair SSH identity: The development Mac did not accept its SSH credentials."),
        (.connectSSH, "Connect over SSH: The development Mac did not accept its SSH credentials.")
    ])
    func guestAuthenticationDoesNotSendUsersToProviderAccounts(_ example: (DiagnosticEvent.Operation, String)) throws {
        let event = DiagnosticEvent(operation: example.0, outcome: .failed(.guestAuthenticationFailed), operationID: Self.operationID)
        #expect(event.message == example.1)
        #expect(event.recoveryMessage == "Open the development Mac console to check the guest account. Resume pairing with the correct guest-only password, or use Repair for key-based access. Keep the pinned host identity; do not bypass verification.")
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test func unverifiedXcodeImportOffersAStableVerifiedSource() throws {
        let event = DiagnosticEvent(operation: .importXcode, outcome: .failed(.verificationFailed), operationID: Self.operationID)
        #expect(event.message == "Import Xcode: The Xcode bundle failed verification.")
        #expect(event.recoveryMessage == "Use Repair to inspect the failed import, then select a trusted, stable Xcode bundle and import it again. Preserve the existing installation until verification succeeds; do not bypass signature checks.")
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test(arguments: [DiagnosticEvent.Operation.downloadRuntime, .downloadGuestImage])
    func diskExhaustedDownloadsRequireStagingInspection(_ operation: DiagnosticEvent.Operation) {
        let event = DiagnosticEvent(operation: operation, outcome: .failed(.insufficientDiskSpace), operationID: Self.operationID)
        #expect(event.recoveryMessage == "Free disk space, then use Repair to inspect the staged download before resuming it.")
    }

    @Test(arguments: [
        (DiagnosticEvent.Operation.downloadRuntime, "Download runtime: The required network connection could not be established."),
        (.downloadGuestImage, "Download macOS image: The required network connection could not be established.")
    ])
    func downloadConnectivityDoesNotAssumeGuestSSH(_ example: (DiagnosticEvent.Operation, String)) throws {
        let event = DiagnosticEvent(operation: example.0, outcome: .failed(.connectionFailed), operationID: Self.operationID)
        #expect(event.message == example.1)
        #expect(event.recoveryMessage == "Check Internet access and the trusted download source, then inspect the staged download in Repair before resuming. Do not bypass TLS or verification checks.")
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
    }
}
