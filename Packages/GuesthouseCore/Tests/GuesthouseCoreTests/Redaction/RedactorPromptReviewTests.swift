import Testing
@testable import GuesthouseCore

@Suite struct RedactorPromptReviewTests {
    @Test(arguments: ["\\\"", "\\'", "\\\\\\\""])
    func encodedQuotedCodesPreserveTheirDiagnosticSuffix(quote: String) {
        let input = "Your code is " + quote + "synthetic secret value" + quote + ", valid for 15 minutes\nstatus: ready"
        #expect(Redactor().redact(input) == "Your code is [redacted:device-code], valid for 15 minutes\nstatus: ready")
    }

    @Test(arguments: [
        ("Enter the code:", "ABC123"), ("Enter this code:", "abcdef"),
        ("Paste a code=", "tiny"), ("Copy your code:", "synthetic value"),
    ])
    func delimitedImperativePromptsRemoveOpaqueValues(prompt: String, value: String) {
        let redactor = Redactor()
        #expect(redactor.redact(prompt + " " + value) == prompt + " [redacted:device-code]")
        #expect(redactor.redact(lines: [prompt, "", value, "done"]).map(\.text)
            == [prompt, "", "[redacted:device-code]", "done"])
    }
}
