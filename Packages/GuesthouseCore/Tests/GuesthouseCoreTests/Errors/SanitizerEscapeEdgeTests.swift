import Testing
@testable import GuesthouseCore

/// Synthetic fragments exercise the sanitizer's inspection of bytes consumed by terminal escapes.
struct SanitizerEscapeEdgeTests {
    @Test(arguments: [("\u{1B}]", "\u{07}"), ("\u{1B}P", "\u{1B}\\"), ("\u{9D}", "\u{9C}"), ("\u{90}", "\u{9C}")],
          ["\u{1B}[31m", "\u{9B}31m", "\u{1B}(B"])
    func nestedPayloadControlsCannotHideARecoveredPrefix(control: (String, String), nested: String) {
        let output = SanitizedText.sanitize(control.0 + "g" + nested + control.1 + "hp_syntheticCredential")
        #expect(!output.contains("synthetic"))
    }

    @Test(arguments: ["(", ")", "*", "+"], ["B", "0"])
    func charsetDesignationsCannotConsumeTheFirstCredentialCharacter(designation: String, final: String) {
        #expect(SanitizedText.sanitize("\u{1B}" + designation + final + "123-C456") == "[redacted:spliced-escape]")
    }

    @Test(arguments: ["B", "0"])
    func charsetDesignationsCannotConsumeTheLastCredentialCharacter(final: String) {
        #expect(SanitizedText.sanitize("B123-C45\u{1B}(" + final) == "[redacted:spliced-escape]")
    }

    @Test(arguments: [
        ("\u{1B}]", "\u{07}"), ("\u{9D}", "\u{9C}"),
        ("\u{1B}P", "\u{1B}\\"), ("\u{90}", "\u{9C}"),
        ("\u{1B}_", "\u{1B}\\"), ("\u{9F}", "\u{9C}"),
        ("\u{1B}^", "\u{1B}\\"), ("\u{9E}", "\u{9C}"),
        ("\u{1B}X", "\u{1B}\\"), ("\u{98}", "\u{9C}"),
    ], [
        ("", "B", "123-C456"), ("", "B12", "3-C456"),
        ("B123-C45", "6", ""), ("B123-C4", "56", ""),
    ])
    func controlPayloadsCannotConsumeCredentialEdges(control: (String, String), parts: (String, String, String)) {
        let input = parts.0 + control.0 + parts.1 + control.1 + parts.2
        #expect(SanitizedText.sanitize(input) == "[redacted:spliced-escape]")
    }

    @Test(arguments: [
        "\u{1B}]B1\u{07}\u{1B}[0m23-C456",
        "\u{1B}[31m\u{1B}(B123-C456",
        "B123-C45\u{1B}[0m\u{1B}(B",
        "\u{1B}]B\u{07}\u{1B}]1\u{07}23-C456",
    ])
    func adjacentHarmlessControlsCannotHideCredentialFragments(input: String) {
        #expect(SanitizedText.sanitize(input) == "[redacted:spliced-escape]")
    }

    @Test(arguments: [
        "\u{1B}(B123-C456,ghp_abcdefghijklmnopqrst",
        "\u{1B}]B\u{07}123-C456,ghp_abcdefghijklmnopqrst",
        "ghp_abcdefghijklmnopqrst,B123-C45\u{1B}(B",
    ])
    func anotherCredentialCannotSuppressEdgeRecovery(input: String) {
        #expect(SanitizedText.sanitize(input) == "[redacted:spliced-escape]")
    }

    @Test(arguments: ["password:", "password=first", "Authorization:", "token:", "device_code=first", "user_code=first"], [true, false])
    func replacingALabelCannotDetachItsFollowingValue(label: String, leadingControl: Bool) {
        let decorated = leadingControl ? "\u{1B}]0;\u{07}" + label : label + "\u{1B}(B"
        let output = SanitizedText.sanitize(decorated + " opaqueValue secondValue")
        #expect(!output.contains("opaqueValue"))
        #expect(!output.contains("secondValue"))
    }

    @Test(arguments: ["\u{1B}]0;\u{07}--password", "--password\u{1B}(B"])
    func ordinaryFollowingArgumentRemainsVisible(option: String) {
        #expect(SanitizedText.sanitize(option + " opaqueValue file.txt") == "--password [redacted:secret] file.txt")
    }

    @Test(arguments: ["\u{0301}", "\u{200D}", "\u{00A0}", "\n"], ["\u{1B}(B", "\u{1B}]B\u{07}"])
    func normalizationCannotHideRecoveredEdges(removed: String, edge: String) {
        #expect(SanitizedText.sanitize(edge + "12" + removed + "3-C456") == "[redacted:spliced-escape]")
    }

    @Test(arguments: ["\u{0301}", "\u{200D}", "\u{00A0}", "\n"])
    func payloadRecoveryUsesTheSameNormalization(removed: String) {
        #expect(SanitizedText.sanitize("\u{1B}]B1" + removed + "2\u{07}3-C456") == "[redacted:spliced-escape]")
    }

    @Test(arguments: ["\u{1B}P", "\u{90}", "\u{1B}_", "\u{9F}", "\u{1B}^", "\u{9E}", "\u{1B}X", "\u{98}"], ["\u{9C}", "\u{1B}\\"])
    func belInsideNonOSCPayloadCannotExposeTheRemainingPayload(introducer: String, terminator: String) {
        let input = "AB12" + introducer + "x\u{07}CD34 interactionControlValue tail" + terminator + " complete"
        let output = SanitizedText.sanitize(input)
        #expect(!output.contains("interactionControlValue"))
        #expect(!output.contains("CD34"))
        #expect(output.hasSuffix(" complete"))
    }

    @Test(arguments: [
        "\u{1B}[32m2.36.0\u{1B}[m", "\u{9B}31m2.36.0\u{9B}0m",
        "\u{1B}(B2.36.0\u{1B}[m\u{1B}(B", "2.36.0\u{1B}(0",
        "\u{1B}]0;window title\u{07}2.36.0", "\u{1B}]0;window title\u{1B}\\2.36.0",
    ])
    func ordinaryVersionStylingRemainsVisible(input: String) {
        #expect(SanitizedText.sanitize(input) == "2.36.0")
    }

    @Test func unterminatedControlPayloadIsRemovedAsAWhole() {
        #expect(SanitizedText.sanitize("version 2.36.0 \u{1B}Pfirst\u{07} remainingOpaquePayload") == "version 2.36.0 ")
    }

    @Test func ordinaryDiagnosticsRemainUnchanged() {
        #expect(SanitizedText.sanitize("Build completed in 12 seconds.") == "Build completed in 12 seconds.")
    }

    @Test func isolatedControlPayloadCannotConsumeAnUnrelatedDiagnostic() {
        #expect(SanitizedText.sanitize("\u{1B}]password: hidden\u{07} version 2.36.0") == " version 2.36.0")
    }

    @Test func originalProbeCandidatesCannotPreserveAFollowingSecret() {
        let prefix = "guesthouseSanitizerFollowingValue0 guesthouseSanitizerFollowingValue1 "
        let output = SanitizedText.sanitize(prefix + "\u{1B}]0;\u{07}device_code=first opaqueValue", limit: 200)
        #expect(output == prefix + "[redacted:spliced-escape]")
    }

    @Test func denseSplicedRunsStayWithinTheBoundedInspectionWindow() {
        let run = "AB12-\u{1B}(BD34"
        let count = (SanitizedText.maximumLimit + SanitizedText.sanitizeLookahead) / (run.unicodeScalars.count + 1)
        let input = Array(repeating: run, count: count).joined(separator: " ")
        let output = SanitizedText.sanitize(input, limit: SanitizedText.maximumLimit)
        #expect(!output.contains("AB12"))
        #expect(output.hasPrefix("[redacted:spliced-escape]"))
    }
}
