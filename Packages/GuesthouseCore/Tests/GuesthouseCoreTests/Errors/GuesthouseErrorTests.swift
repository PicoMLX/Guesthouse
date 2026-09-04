import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct GuesthouseErrorTests {
    static let storageDrift = RuntimeStorageProblem(
        kind: .protectionDrift,
        path: "/private/Guesthouse/vms",
        detail: "permissions are not 0700"
    )

    /// One representative value per case. Keep in sync with `expectedCaseNames`; the exhaustive
    /// switches in `GuesthouseError` force a source update when a case is added.
    static let samples: [GuesthouseError] = [
        .unsupportedHost(.notAppleSilicon),
        .unsupportedHost(.macOSTooOld(found: "15.6", minimum: "26.4")),
        .unsupportedHost(.insufficientMemory(foundBytes: 8 << 30, minimumBytes: 16 << 30)),
        .insufficientDisk(requiredBytes: 200_000_000_000, availableBytes: 50_000_000_000, volumePath: "/"),
        .downloadVerificationFailed(artifact: "Tart 2.36.0", check: .digest),
        .runtimeStorageUnavailable(storageDrift),
        .runtimeMissing,
        .runtimeIncompatible(found: "2.30.0", required: "2.36.0"),
        .runtimeProbeFailed,
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
        "unsupportedHost", "insufficientDisk", "downloadVerificationFailed", "runtimeStorageUnavailable", "runtimeMissing",
        "runtimeIncompatible", "runtimeProbeFailed", "guestNotReachable", "hostKeyChanged", "credentialsLocked",
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
        #expect(!GuesthouseError.runtimeStorageUnavailable(Self.storageDrift).isRetryable)
        #expect(!GuesthouseError.runtimeProbeFailed.isRetryable)
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
        #expect(error.userMessage.contains("150 GB short"))
        let close = GuesthouseError.insufficientDisk(requiredBytes: 200_000_000_000, availableBytes: 199_999_999_999, volumePath: "/")
        #expect(close.userMessage.contains("200,000,000,000 bytes"))
        #expect(close.userMessage.contains("199,999,999,999 bytes"))
        #expect(close.userMessage.contains("1 bytes short"))
    }

    @Test func sanitizerBoundsItsInputBeforeWorking() {
        let huge = String(repeating: "x", count: 5_000_000)
        let started = ContinuousClock.now
        let error = GuesthouseError.toolMismatch(tool: huge, found: nil, expected: "1.0")
        #expect(error.userMessage.unicodeScalars.count < 400)
        #expect(ContinuousClock.now - started < .seconds(2))
        let lateSecret = String(repeating: "x", count: 60) + " ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        #expect(!GuesthouseError.toolMismatch(tool: lateSecret, found: nil, expected: "1").userMessage.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
    }

    @Test func memoryMessagesUseBinaryUnits() {
        let error = GuesthouseError.unsupportedHost(.insufficientMemory(foundBytes: 8 << 30, minimumBytes: 16 << 30))
        #expect(error.userMessage.contains("8 GB"))
        #expect(error.userMessage.contains("16 GB"))
    }

    @Test func untrustedValuesAreSanitizedBeforeInterpolation() {
        let injected = "codex\nInjected: secret line\u{2028}more"
        let long = String(repeating: "x", count: 200)
        let error = GuesthouseError.toolMismatch(tool: injected, found: SanitizedText(long), expected: "1.0")
        #expect(!error.userMessage.contains("\n"))
        #expect(!error.userMessage.contains("\u{2028}"))
        #expect(error.userMessage.contains("codexInjected: secret linemore"))
        #expect(!error.userMessage.contains(long))
        #expect(error.userMessage.contains(String(repeating: "x", count: 80) + "…"))
        #expect(!error.redactedDescription.contains("\n"))
    }

    @Test func credentialsInUntrustedValuesAreRedactedNotJustTruncated() {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let probe = GuesthouseError.toolMismatch(tool: "gh", found: SanitizedText(token), expected: "2.80.0")
        #expect(!probe.userMessage.contains(token))
        #expect(probe.userMessage.contains("[redacted:github-token]"))
        #expect(!probe.redactedDescription.contains(token))

        let header = GuesthouseError.downloadVerificationFailed(artifact: "Authorization: Bearer abcdefghijklmnop", check: .digest)
        #expect(!header.redactedDescription.contains("abcdefghijklmnop"))
        #expect(header.redactedDescription.contains("[redacted:authorization]"))
    }

    @Test func splitTokensBidiControlsAndBareDeviceCodesAreNeutralized() {
        let split = GuesthouseError.toolMismatch(tool: "gh", found: "ghp_\nABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", expected: "2.80.0")
        #expect(!split.redactedDescription.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(split.redactedDescription.contains("[redacted:github-token]"))

        let bidi = GuesthouseError.downloadVerificationFailed(artifact: "Tart\u{202E}gnp.evil", check: .digest)
        #expect(!bidi.userMessage.contains("\u{202E}"))
        #expect(bidi.userMessage.contains("Tartgnp.evil"))

        let code = GuesthouseError.toolMismatch(tool: "codex", found: "AB12-CD34", expected: "1.0")
        #expect(!code.redactedDescription.contains("AB12-CD34"))
        #expect(code.redactedDescription.contains("[redacted:device-code]"))
    }

    @Test func sanitizedValuesAreBoundedInUnicodeScalarsAndCombiningMarksAreDropped() {
        let combining = "a" + String(repeating: "\u{0301}", count: 500)
        let error = GuesthouseError.toolMismatch(tool: combining, found: nil, expected: "1.0")
        #expect(!error.userMessage.unicodeScalars.contains("\u{0301}"))
        #expect(error.userMessage.contains("has a missing"))
        let wide = String(repeating: "\u{1F600}", count: 200)
        let long = GuesthouseError.toolMismatch(tool: wide, found: nil, expected: "1.0")
        #expect(long.userMessage.unicodeScalars.count < 400)
        #expect(long.userMessage.contains("…"))
    }

    @Test func hostAndToolErrorsOfferActionableRoutes() {
        #expect(GuesthouseError.unsupportedHost(.macOSTooOld(found: "26.0", minimum: "26.4")).recoveryActions.first == .openSettings)
        #expect(GuesthouseError.unsupportedHost(.notAppleSilicon).recoveryActions == [.cancel])
        for error in [GuesthouseError.toolMismatch(tool: "codex", found: "1", expected: "2"), .xcodeComponentsIncomplete(missing: ["x"])] {
            #expect(error.recoveryActions.contains(.openConsole))
            #expect(error.recoveryActions.contains(.exportWork))
        }
        #expect(GuesthouseError.runtimeIncompatible(found: "1", required: "2").recoveryActions.contains(.exportWork))
    }

    @Test func runtimeStorageRecoveryPreservesWorkAndMatchesTheCause() throws {
        let path = "/private/Guesthouse/vms"
        let drift = GuesthouseError.runtimeStorageUnavailable(.init(
            kind: .protectionDrift,
            path: path,
            detail: "permissions are not 0700"
        ))
        let insecure = GuesthouseError.runtimeStorageUnavailable(.init(
            kind: .insecureDirectory,
            path: path,
            detail: "symbolic link"
        ))
        let unwritable = GuesthouseError.runtimeStorageUnavailable(.init(
            kind: .unwritable,
            path: path,
            detail: "No space left on device"
        ))

        for error in [drift, insecure, unwritable] {
            #expect(error.userMessage.contains("unpublished work"))
            #expect(!error.recoveryActions.contains(.openSettings))
            #expect(!error.recoveryActions.contains(.retry))
            #expect(!error.userMessage.contains("move or remove"))
            #expect(!error.userMessage.contains("delete"))
            let encoded = try JSONEncoder().encode(error)
            #expect(try JSONDecoder().decode(GuesthouseError.self, from: encoded) == error)
        }
        #expect(drift.userMessage.contains("Quit and reopen Guesthouse"))
        #expect(drift.recoveryActions == [.cancel])
        #expect(insecure.userMessage.contains("Preserve"))
        #expect(insecure.recoveryActions == [.cancel])
        #expect(unwritable.recoveryActions == [.freeDiskSpace, .cancel])
        #expect(unwritable.recoverySuggestion == "Free disk space or restore write access, then quit and reopen Guesthouse.")
        #expect(!unwritable.recoverySuggestion!.contains("try again"))
    }

    @Test func decodedRuntimeStorageContextIsRedactedAndFieldBounded() throws {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let raw: [String: String] = [
            "kind": "unwritable",
            "path": "/private/\n\(token)/" + String(repeating: "p", count: 2_000),
            "detail": "Authorization: Bearer abcdefghijklmnop\n" + String(repeating: "d", count: 2_000),
        ]
        let problem = try JSONDecoder().decode(
            RuntimeStorageProblem.self,
            from: JSONEncoder().encode(raw)
        )
        #expect(problem.path.value.unicodeScalars.count <= 201)
        #expect(problem.detail.value.unicodeScalars.count <= 121)
        #expect(!problem.path.value.contains("\n"))
        #expect(!problem.path.value.contains(token))
        #expect(!problem.detail.value.contains("abcdefghijklmnop"))

        let encoded = String(decoding: try JSONEncoder().encode(problem), as: UTF8.self)
        #expect(!encoded.contains(token))
        #expect(!encoded.contains("abcdefghijklmnop"))
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
