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

    @Test func environmentCapacityUsesTheDomainErrorPath() throws {
        let error = GuesthouseError.vmSlotUnavailable(maximum: 2)
        let event = DiagnosticEvent(operation: .createEnvironment, outcome: .operationFailed(error), operationID: Self.uuid)
        #expect(event.message == "Create development Mac: All 2 supported environment slots are in use, including stopped environments.")
        #expect(error.recoveryActions == [.exportWork, .deleteEnvironment, .cancel])
        #expect(event.recoveryMessage == "Export unpublished work; Delete an unused environment after exporting its work; Cancel")
        #expect(!error.isRetryable)
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
        var log = DiagnosticLog()
        log.append(event, recordedAt: Date(timeIntervalSince1970: 0))
        #expect(log.text.contains("All 2 supported environment slots are in use"))
        #expect(log.text.contains("Delete an unused environment after exporting its work"))
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

    @Test(arguments: [
        (GuesthouseError.VerificationCheck.digest, "The downloaded artifact failed its checksum verification check."),
        (.signature, "The downloaded artifact failed its signature verification check."),
        (.size, "The downloaded artifact failed its size verification check.")
    ], [DiagnosticEvent.Operation.downloadGuestImage, .downloadRuntime])
    func downloadErrorsDoNotAssumeTheArtifactIsARuntime(_ example: (GuesthouseError.VerificationCheck, String), _ operation: DiagnosticEvent.Operation) throws {
        let error = GuesthouseError.downloadVerificationFailed(check: example.0)
        let event = DiagnosticEvent(operation: operation, outcome: .operationFailed(error), operationID: Self.uuid)
        #expect(error.userMessage == example.1)
        #expect(error.recoveryActions == [.repair(.download), .cancel])
        #expect(event.recoveryMessage == "Download a verified replacement from the trusted source without bypassing verification; Cancel")
        #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test(arguments: [
        (GuesthouseError.InvalidRequestReason.oversized, "The request exceeds Guesthouse's supported size limit."),
        (.pathEscapesAllowedRoot, "The request refers to a location outside the allowed workspace or environment."),
        (.invalidVMName, "The request contains an invalid development Mac name."),
        (.unsupportedOperation, "This version of Guesthouse does not support the requested operation."),
        (.malformed, "The request is incomplete or has an invalid format.")
    ])
    func requestRejectionsUseReadableExplanations(_ example: (GuesthouseError.InvalidRequestReason, String)) {
        #expect(GuesthouseError.invalidRequest(example.0).userMessage == example.1)
    }

    @Test(arguments: [
        (GuesthouseError.Tool.xcode, "Xcode"), (.swift, "Swift"), (.git, "Git"),
        (.githubCLI, "GitHub CLI"), (.codexCLI, "Codex CLI"), (.ssh, "SSH"), (.vmRuntime, "virtual machine runtime")
    ])
    func toolErrorsUseProductNames(_ example: (GuesthouseError.Tool, String)) {
        #expect(GuesthouseError.toolMismatch(tool: example.0).userMessage == "The required tool (" + example.1 + ") is missing or incompatible.")
    }

    @Test(arguments: [GuesthouseError.runtimeMissing, .runtimeIncompatible, .toolMismatch(tool: .vmRuntime)])
    func runtimeRepairDoesNotRequireAWorkingVM(_ error: GuesthouseError) {
        #expect(error.category == .runtime)
        #expect(error.recoveryActions == [.repair(.runtime), .cancel])
        #expect(error.recoveryMessage == "Repair the verified runtime installation; Cancel")
        #expect(!error.isRetryable)
    }
}
