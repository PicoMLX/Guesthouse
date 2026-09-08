import Foundation
import GuesthouseCore
import Testing

struct GuesthouseErrorTests {
    private static let uuid = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let examples: [GuesthouseError] = [
        .unsupportedHost(.notAppleSilicon), .unsupportedHost(.unknownArchitecture),
        .unsupportedHost(.macOSTooOld), .unsupportedHost(.insufficientMemory(foundBytes: 1, minimumBytes: 2)),
        .insufficientDisk(requiredBytes: 2, availableBytes: 1), .runtimeMissing, .runtimeIncompatible,
        .guestNotReachable(EnvironmentID(uuid: uuid)), .hostKeyChanged(EnvironmentID(uuid: uuid)),
        .xcodeComponentsIncomplete, .vmSlotUnavailable(maximum: 2), .operationOutcomeUnknown(OperationID(uuid: uuid)),
        .unauthorizedCaller, .protocolMismatch(client: 1, service: 2), .canceled
    ] + GuesthouseError.VerificationCheck.allCases.map { .downloadVerificationFailed(check: $0) }
      + GuesthouseError.CredentialStore.allCases.map { .credentialsLocked($0) }
      + GuesthouseError.Provider.allCases.map { .loginExpired($0) }
      + GuesthouseError.Tool.allCases.map { .toolMismatch(tool: $0) }
      + GuesthouseError.InvalidRequestReason.allCases.map { .invalidRequest($0) }

    @Test(arguments: examples)
    func roundTripAndPresentation(_ error: GuesthouseError) throws {
        #expect(!error.userMessage.isEmpty)
        #expect(!error.recoveryActions.isEmpty)
        #expect(error.errorDescription == error.userMessage)
        #expect(error.recoverySuggestion == error.recoveryMessage)
        #expect(try JSONDecoder().decode(GuesthouseError.self, from: JSONEncoder().encode(error)) == error)
        let event = DiagnosticEvent(operation: .checkTools, outcome: .operationFailed(error), operationID: Self.uuid)
        #expect(event.message == "Check tools: " + error.userMessage)
        #expect(event.recoveryMessage == error.recoveryMessage)
        var log = DiagnosticLog()
        log.append(event, recordedAt: Date(timeIntervalSince1970: 0))
        let json = try #require(JSONSerialization.jsonObject(with: log.jsonData()) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 2)
        #expect(log.text.contains(error.userMessage))
        #expect(log.text.contains(error.recoveryMessage))
    }

    @Test func uncertainOutcomesDoNotOfferBlindRetry() {
        let error = GuesthouseError.operationOutcomeUnknown(OperationID(uuid: Self.uuid))
        #expect(error.recoveryActions == [.inspectState, .cancel])
        #expect(!error.isRetryable)
        #expect(GuesthouseError.canceled.recoveryActions == [.inspectState, .cancel])
        #expect(GuesthouseError.hostKeyChanged(EnvironmentID(uuid: Self.uuid)).recoveryActions.first == .repair(.sshPairing))
    }

    @Test func noRawErrorPayloadSurvivesDecodeAndExport() throws {
        let input = Data(#"{"runtimeMissing":{},"message":"syntheticOpaque","underlyingError":"syntheticOpaque"}"#.utf8)
        let error = try JSONDecoder().decode(GuesthouseError.self, from: input)
        #expect(error == .runtimeMissing)
        #expect(try JSONEncoder().encode(error) == JSONEncoder().encode(GuesthouseError.runtimeMissing))
        #expect(error.description == "runtime: The virtual machine runtime is not installed.")
    }

    @Test func pathsCannotBeSmuggledInAsToolNames() {
        let input = Data(#"{"toolMismatch":{"tool":"/private/syntheticOpaque"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GuesthouseError.self, from: input) }
    }

    @Test func operationIdentityUsesTheExistingUUIDWireShape() throws {
        let identity = OperationID(uuid: Self.uuid)
        #expect(try JSONEncoder().encode(identity) == JSONEncoder().encode(Self.uuid))
        #expect(try JSONDecoder().decode(OperationID.self, from: JSONEncoder().encode(identity)) == identity)
    }
}
