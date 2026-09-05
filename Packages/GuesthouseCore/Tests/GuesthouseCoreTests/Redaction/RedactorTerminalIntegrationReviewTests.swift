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
}
