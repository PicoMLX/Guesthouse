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
        .runtimeStateUnavailable(reason: "the operation journal could not be opened"),
        .runtimeStorageUnavailable(reason: "the storage folder is full", problem: .unwritable),
        .runtimeStorageUnavailable(reason: "a containing folder can be changed by other users", problem: .unsafeLocation),
        .runtimeVerificationFailed(check: .signature),
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
        .environmentNotFound(EnvironmentID()),
        .environmentAlreadyRunning(EnvironmentID()),
        .operationInFlight(OperationID()),
        .operationOutcomeUnknown(OperationID()),
        .unauthorizedCaller,
        .protocolMismatch(client: 2, service: 1),
        .invalidRequest(.pathEscapesAllowedRoot),
        .canceled,
    ]

    static let expectedCaseNames: Set<String> = [
        "unsupportedHost", "insufficientDisk", "downloadVerificationFailed", "runtimeMissing",
        "runtimeStateUnavailable", "runtimeStorageUnavailable",
        "runtimeVerificationFailed", "runtimeIncompatible", "guestNotReachable", "hostKeyChanged", "credentialsLocked",
        "loginExpired", "toolMismatch", "xcodeComponentsIncomplete", "vmSlotUnavailable",
        "operationOutcomeUnknown", "unauthorizedCaller", "protocolMismatch", "invalidRequest",
        "canceled", "environmentNotFound", "environmentAlreadyRunning", "operationInFlight",
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
        #expect(error.userMessage.contains("150 GB short"))
        let close = GuesthouseError.insufficientDisk(requiredBytes: 200_000_000_000, availableBytes: 199_999_999_999, volumePath: "/")
        #expect(close.userMessage.contains("200,000,000,000 bytes"))
        #expect(close.userMessage.contains("199,999,999,999 bytes"))
        #expect(close.userMessage.contains("1 bytes short"))
    }

    @Test func sanitizerBoundsItsInputBeforeWorking() {
        let huge = String(repeating: "x", count: 5_000_000)
        let started = ContinuousClock.now
        let error = GuesthouseError.toolMismatch(tool: SanitizedText(huge), found: nil, expected: "1.0")
        #expect(error.userMessage.unicodeScalars.count < 400)
        #expect(ContinuousClock.now - started < .seconds(2))
        let lateSecret = String(repeating: "x", count: 60) + " ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        #expect(!GuesthouseError.toolMismatch(tool: SanitizedText(lateSecret), found: nil, expected: "1").userMessage.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
    }

    @Test func memoryMessagesUseBinaryUnits() {
        let error = GuesthouseError.unsupportedHost(.insufficientMemory(foundBytes: 8 << 30, minimumBytes: 16 << 30))
        #expect(error.userMessage.contains("8 GB"))
        #expect(error.userMessage.contains("16 GB"))
    }

    @Test func untrustedValuesAreSanitizedBeforeInterpolation() {
        let injected = "codex\nInjected: secret line\u{2028}more"
        let long = String(repeating: "x", count: 200)
        let error = GuesthouseError.toolMismatch(tool: SanitizedText(injected), found: SanitizedText(long), expected: "1.0")
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
        let error = GuesthouseError.toolMismatch(tool: SanitizedText(combining), found: nil, expected: "1.0")
        #expect(!error.userMessage.unicodeScalars.contains("\u{0301}"))
        #expect(error.userMessage.contains("has a missing"))
        let wide = String(repeating: "\u{1F600}", count: 200)
        let long = GuesthouseError.toolMismatch(tool: SanitizedText(wide), found: nil, expected: "1.0")
        #expect(long.userMessage.unicodeScalars.count < 400)
        #expect(long.userMessage.contains("…"))
    }

    @Test func separatorsAndSplicedEscapesCannotSmuggleACredentialThrough() {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let spaced = GuesthouseError.toolMismatch(tool: "gh", found: "ghp_\u{00A0}ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", expected: "1")
        #expect(!spaced.redactedDescription.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(spaced.redactedDescription.contains("[redacted:github-token]"))
        #expect(GuesthouseError.sanitize("tart 2.36.0") == "tart 2.36.0", "an ordinary space is still a word boundary")
        #expect(!GuesthouseError.sanitize("ghp_\u{2007}\(token.dropFirst(4))").contains("ABCDEF"))

        // The escape has no parameters, so its terminator is the credential's own `C`.
        let spliced = GuesthouseError.toolMismatch(tool: "codex", found: "AB12-\u{1B}[CD34", expected: "1")
        #expect(!spliced.redactedDescription.contains("D34"))
        #expect(spliced.redactedDescription.contains("[redacted:spliced-escape]"))
        #expect(GuesthouseError.sanitize("\u{1B}[31m2.36.0\u{1B}[0m") == "2.36.0", "parameterized styling is still just stripped")
    }

    @Test func aJWTCutByTheSanitizerWindowIsStillRedacted() {
        let header = "eyJhbGciOiJIUzI1NiJ9"
        let jwt = "\(header).\(String(repeating: "A", count: 700)).c2ln"
        let message = GuesthouseError.toolMismatch(tool: "gh", found: SanitizedText(jwt), expected: "1").userMessage
        #expect(!message.contains(header))
        #expect(!message.contains("AAAA"))
        #expect(message.contains("[redacted:jwt]"))
        // The same shape without a JOSE header is a long dotted name, and survives the cut.
        let dotted = String(repeating: "a", count: 300) + "." + String(repeating: "b", count: 400)
        #expect(GuesthouseError.sanitize(dotted).hasPrefix(String(repeating: "a", count: 80)))
    }

    @Test func outOfRangeSanitizerLimitsAreClampedNotFatal() {
        #expect(GuesthouseError.sanitize("hello", limit: .max) == "hello")
        #expect(GuesthouseError.sanitize("hello", limit: .min) == "h…")
        #expect(GuesthouseError.sanitize("hello", limit: 0) == "h…")
        #expect(GuesthouseError.sanitize(String(repeating: "x", count: 5_000), limit: .max).unicodeScalars.count == SanitizedText.maximumLimit + 1)
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

    @Test func slotAndProtocolErrorsOfferTheRealRemedy() {
        let slots = GuesthouseError.vmSlotUnavailable(maximum: 2).recoveryActions
        #expect(slots.firstIndex(of: .exportWork)! < slots.firstIndex(of: .deleteEnvironment)!)
        #expect(GuesthouseError.vmSlotUnavailable(maximum: 2).userMessage.contains("then delete"))
        #expect(GuesthouseError.protocolMismatch(client: 2, service: 1).recoveryActions.first == .reinstallApp)
    }

    @Test func parameterizedAndNonCSISplicesAreAlsoRedacted() {
        // The escape carries a parameter, and the second is not a CSI at all, but in both the
        // terminator is the device code's own `C`.
        #expect(GuesthouseError.sanitize("AB12-\u{1B}[0CD34") == "[redacted:spliced-escape]")
        #expect(GuesthouseError.sanitize("AB12-\u{1B}(CD34") == "[redacted:spliced-escape]")
    }

    @Test func sequencesATerminalWritesLeaveTheValueAlone() {
        #expect(GuesthouseError.sanitize("\u{1B}[32m2.36\u{1B}[m") == "2.36")
        #expect(GuesthouseError.sanitize("\u{1B}(B2.36.0\u{1B}[m\u{1B}(B") == "2.36.0")
    }

    @Test func aCharsetDesignationInsideARunIsStillASplice() {
        // `ESC ( B` is what a terminal writes, but `B` and `0` are characters a device code is
        // made of, so one standing between two of them may have been the value's own.
        #expect(GuesthouseError.sanitize("AB12-\u{1B}(BD34") == "[redacted:spliced-escape]")
        #expect(GuesthouseError.sanitize("AB12-\u{1B}(0CD34") == "[redacted:spliced-escape]")
    }

    @Test func anSGRInsideARunIsStillASplice() {
        // `m` is a Base64URL character too, and the JWT rule is structural rather than a prefix
        // and a length: a JOSE header that loses one character to `ESC [` standing in front of
        // its own `m` no longer decodes, and the whole token would be reported in the clear.
        let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IjEifQ"
        let jwt = "\(header).eyJzdWIiOiIxIn0.c2lnbmF0dXJl"
        #expect(GuesthouseError.sanitize(jwt) == "[redacted:jwt]")
        let spliced = jwt.replacingOccurrences(of: "Imtp", with: "I\u{1B}[mtp")
        #expect(!GuesthouseError.sanitize(spliced).contains("c2lnbmF0dXJl"))
        #expect(GuesthouseError.sanitize(spliced) == "[redacted:spliced-escape]")
    }

    @Test func aCredentialPaddedOutOfTheWindowDoesNotSurviveAsAFragment() {
        // Exactly enough marks to push the code's last character past the window.
        let marks = String(repeating: "\u{0301}", count: GuesthouseError.sanitizeLookahead + SanitizedText.defaultLimit - 8)
        let padded = "AB12-CD3" + marks + "4"
        #expect(!GuesthouseError.sanitize(padded).contains("AB12-CD3"))
    }

    @Test func aControlStringInsideARunIsASpliceToo() {
        // A control string's payload runs to a terminator the sender chooses, so an OSC planted
        // between two characters of a value takes as much of it as the sender likes. Here it
        // takes the device code's separator: stripping alone left `AB12CD34`, which no pattern
        // recognizes and which is the whole code.
        #expect(GuesthouseError.sanitize("AB12\u{1B}]\u{07}CD34") == "[redacted:spliced-escape]")
        #expect(GuesthouseError.sanitize("AB12-\u{1B}]x\u{07}D34") == "[redacted:spliced-escape]")
        #expect(GuesthouseError.sanitize("AB12\u{1B}Pxx\u{1B}\\CD34") == "[redacted:spliced-escape]")
        // At the edge of a run it is the title sequence a terminal really writes, and the value
        // beside it keeps its own text.
        #expect(GuesthouseError.sanitize("\u{1B}]0;window title\u{07}2.36.0") == "2.36.0")
    }

    @Test func aJWTGluedToANameSurvivesNeitherTheCutoffNorTheWindow() {
        // Truncation takes the second dot, so the complete-JWT rule cannot match and the cutoff
        // repair is the only thing left. It has to look for the JOSE header after the `_` the
        // way `redactedJWT` does, or `artifact_` in front of it hides the header from it.
        let header = "eyJhbGciOiJIUzI1NiJ9"
        let payload = String(repeating: "a", count: 700)
        let sanitized = GuesthouseError.sanitize("artifact_\(header).\(payload).c2lnbmF0dXJl")
        #expect(sanitized == "artifact_[redacted:jwt]")
    }

    @Test func operationIDEncodesAsBareUUID() throws {
        let id = OperationID()
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(id.uuid.uuidString)\"")
    }
}
