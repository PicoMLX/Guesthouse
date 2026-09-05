import Testing
@testable import GuesthouseCore

/// The error sanitizer must use the same credential grammar as the canonical redactor.
struct SanitizerCanonicalIntegrationTests {
    @Test(arguments: ["artifact", "artifact_", "artifact-"])
    func directlyPrefixedJWTIsRemovedEvenWhenClaimsCrossTheInspectionWindow(prefix: String) {
        let header = "eyJhbGciOiJIUzI1NiJ9"
        let payload = String(repeating: "a", count: 700)
        let output = GuesthouseError.sanitize(prefix + header + "." + payload + ".c2lnbmF0dXJl")
        #expect(output == prefix + "[redacted:jwt]")
        #expect(!output.contains(header))
        #expect(!output.contains("aaaa"))
    }

    @Test(arguments: ["device_code:first", "user_code:first"], [true, false])
    func terminalLabelRecoveryCannotExposeColonDelimitedCodeValues(label: String, leadingControl: Bool) {
        let decorated = leadingControl ? "\u{1B}]0;\u{07}" + label : label + "\u{1B}(B"
        let output = GuesthouseError.sanitize(decorated + " opaqueValue secondValue")
        #expect(!output.contains("first"))
        #expect(!output.contains("opaqueValue"))
        #expect(!output.contains("secondValue"))
    }
}
