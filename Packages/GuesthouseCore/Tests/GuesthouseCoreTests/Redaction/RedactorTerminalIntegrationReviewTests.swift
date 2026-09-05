import Testing
@testable import GuesthouseCore

@Suite struct RedactorTerminalIntegrationReviewTests {
    @Test func terminalRecoveryRetainsPendingLabelsFromTheJoinedReading() {
        let input = "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.password:"
        let output = Redactor().redact(lines: [input, "opaqueSecret", "after"]).map(\.text)
        #expect(output == ["[redacted:jwt]:", "[redacted:secret]", "after"])
    }

    @Test(arguments: ["password: opaqueSecret", "Authorization: Custom opaqueSecret", "user_code: opaqueSecret",
                      "enter the code: opaqueSecret", "enter the code ABC123", "user_code is opaqueSecret"])
    func recoveryCannotHideALabelAndExposeItsCurrentValue(suffix: String) {
        let input = "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload." + suffix
        #expect(Redactor().redact(input) == "[redacted:jwt]")
    }

    @Test func recoveryRetainsTheOriginalPEMBlockState() {
        let opener = "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.-----BEGIN PRIVATE KEY-----"
        let lines = [opener, "syntheticBody", "-----END PRIVATE KEY-----", "after"]
        #expect(Redactor().redact(lines: lines).map(\.text) == ["[redacted:jwt]", "[redacted:private-key]", "[redacted:private-key]", "after"])
    }

    @Test func recoveryCannotExposeAnInlinePEMBody() {
        let input = "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.-----BEGIN PRIVATE KEY-----syntheticBody-----END PRIVATE KEY-----"
        #expect(Redactor().redact(input) == "[redacted:jwt]")
    }

    @Test(arguments: ["sk-abcdefghijklmnopqrstuvwx", "ghp_abcdefghijklmnopqrstuvwx"])
    func malformedCSIIntroducersCannotConsumeCredentialInitials(token: String) {
        let output = Redactor().redact("filename\u{1B}[" + token)
        #expect(!output.contains("abcdefghijklmnopqrstuvwx"))
        #expect(output.hasPrefix("filename[redacted:"))
    }

    @Test func aJWTDoesNotHideABoundaryWithinItsFilenameSuffix() {
        let input = "eyJhbGciOiJIUzI1NiJ9.payload.signature.filename\u{1B}[31msk-abcdefghijklmnopqrstuvwx"
        #expect(Redactor().redact(input) == "[redacted:jwt].filename[redacted:api-key]")
    }
}
