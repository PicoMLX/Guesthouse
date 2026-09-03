import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct GuesthouseErrorTests {
    /// One representative value per case. Keep in sync with `expectedCaseNames`; the exhaustive
    /// switches in `GuesthouseError` force a source update when a case is added.
    static let samples: [GuesthouseError] = [
        .unsupportedHost(.notAppleSilicon),
        .unsupportedHost(.macOSTooOld(found: "15.6", minimum: "26.4")),
        .unsupportedHost(.insufficientMemory(foundBytes: 8 << 30, minimumBytes: 16 << 30)),
        .insufficientDisk(requiredBytes: 200_000_000_000, availableBytes: 50_000_000_000, volumePath: "/"),
        .downloadVerificationFailed(artifact: "Tart 2.36.0", check: .digest),
        .runtimeMissing,
        .runtimeIncompatible(found: "2.30.0", required: "2.36.0"),
        .guestNotReachable(EnvironmentID()),
        .hostKeyChanged(EnvironmentID()),
        .credentialsLocked(.guestKeychain),
        .credentialsLocked(.hostKeychain),
        .loginExpired(.github),
        .loginExpired(.codex),
        .toolMismatch(tool: "codex", found: nil, expected: "0.50.0"),
        .xcodeComponentsIncomplete(missing: ["iOS 26.4 Simulator"]),
        .vmSlotUnavailable(maximum: 2),
        .operationOutcomeUnknown(OperationID()),
        .unauthorizedCaller,
        .protocolMismatch(client: 2, service: 1),
        .invalidRequest(.pathEscapesAllowedRoot),
        .canceled,
    ]

    static let expectedCaseNames: Set<String> = [
        "unsupportedHost", "insufficientDisk", "downloadVerificationFailed", "runtimeMissing",
        "runtimeIncompatible", "guestNotReachable", "hostKeyChanged", "credentialsLocked",
        "loginExpired", "toolMismatch", "xcodeComponentsIncomplete", "vmSlotUnavailable",
        "operationOutcomeUnknown", "unauthorizedCaller", "protocolMismatch", "invalidRequest",
        "canceled",
    ]

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(\.caseName)) == Self.expectedCaseNames)
    }

    @Test(arguments: samples)
    func everyErrorHasMessageAndRecoveryAction(error: GuesthouseError) {
        #expect(!error.userMessage.isEmpty)
        #expect(!error.recoveryActions.isEmpty)
        #expect(error.errorDescription == error.userMessage)
        #expect(error.description == error.redactedDescription)
        #expect(error.description.contains(error.caseName))
    }

    @Test(arguments: samples)
    func everyErrorRoundTripsThroughJSON(error: GuesthouseError) throws {
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(GuesthouseError.self, from: data) == error)
    }

    @Test func unknownOutcomeNeverOffersPlainRetry() {
        let error = GuesthouseError.operationOutcomeUnknown(OperationID())
        #expect(!error.recoveryActions.contains(.retry))
        #expect(error.recoveryActions.first == .inspectState)
        #expect(!error.isRetryable)
    }

    @Test func retryableErrorsOfferRetry() {
        #expect(GuesthouseError.guestNotReachable(EnvironmentID()).isRetryable)
        #expect(GuesthouseError.downloadVerificationFailed(artifact: "x", check: .signature).isRetryable)
        #expect(!GuesthouseError.hostKeyChanged(EnvironmentID()).isRetryable)
        #expect(!GuesthouseError.unauthorizedCaller.isRetryable)
    }

    @Test func hostKeyChangeRequiresRepairNotSilentRepairing() {
        let actions = GuesthouseError.hostKeyChanged(EnvironmentID()).recoveryActions
        #expect(actions.first == .repair(.sshPairing))
        #expect(!actions.contains(.retry))
    }

    @Test func categoriesAreExhaustivelyAssigned() {
        let categories = Set(Self.samples.map(\.category))
        #expect(categories == Set(GuesthouseError.Category.allCases))
    }

    @Test func messagesFormatSizesForHumans() {
        let error = GuesthouseError.insufficientDisk(
            requiredBytes: 200_000_000_000, availableBytes: 50_000_000_000, volumePath: "/"
        )
        #expect(error.userMessage.contains("200 GB"))
        #expect(error.userMessage.contains("50 GB"))
    }

    @Test func memoryMessagesUseBinaryUnits() {
        let error = GuesthouseError.unsupportedHost(.insufficientMemory(foundBytes: 8 << 30, minimumBytes: 16 << 30))
        #expect(error.userMessage.contains("8 GB"))
        #expect(error.userMessage.contains("16 GB"))
    }

    @Test func untrustedValuesAreSanitizedBeforeInterpolation() {
        let injected = "codex\nInjected: secret line\u{2028}more"
        let long = String(repeating: "x", count: 200)
        let error = GuesthouseError.toolMismatch(tool: injected, found: long, expected: "1.0")
        #expect(!error.userMessage.contains("\n"))
        #expect(!error.userMessage.contains("\u{2028}"))
        #expect(error.userMessage.contains("codexInjected: secret linemore"))
        #expect(!error.userMessage.contains(long))
        #expect(error.userMessage.contains(String(repeating: "x", count: 80) + "…"))
        #expect(!error.redactedDescription.contains("\n"))
    }

    @Test func credentialsInUntrustedValuesAreRedactedNotJustTruncated() {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let probe = GuesthouseError.toolMismatch(tool: "gh", found: token, expected: "2.80.0")
        #expect(!probe.userMessage.contains(token))
        #expect(probe.userMessage.contains("[redacted:github-token]"))
        #expect(!probe.redactedDescription.contains(token))

        let header = GuesthouseError.downloadVerificationFailed(artifact: "Authorization: Bearer abcdefghijklmnop", check: .digest)
        #expect(!header.redactedDescription.contains("abcdefghijklmnop"))
        #expect(header.redactedDescription.contains("[redacted:authorization]"))
    }

    @Test func slotAndProtocolErrorsOfferTheRealRemedy() {
        let slots = GuesthouseError.vmSlotUnavailable(maximum: 2).recoveryActions
        #expect(slots.firstIndex(of: .exportWork)! < slots.firstIndex(of: .deleteEnvironment)!)
        #expect(GuesthouseError.vmSlotUnavailable(maximum: 2).userMessage.contains("then delete"))
        #expect(GuesthouseError.protocolMismatch(client: 2, service: 1).recoveryActions.first == .reinstallApp)
    }

    @Test func operationIDEncodesAsBareUUID() throws {
        let id = OperationID()
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(id.uuid.uuidString)\"")
    }
}
