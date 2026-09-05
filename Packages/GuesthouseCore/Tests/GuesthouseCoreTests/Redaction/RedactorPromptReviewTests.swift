import Testing
@testable import GuesthouseCore

@Suite struct RedactorPromptReviewTests {
    @Test(arguments: ["Enter the code:", "Your code is:"], ["Authorization", "password", "device_code"])
    func encodedPromptValuesPreserveFollowingPendingFields(prompt: String, next: String) {
        let q = "\\\""
        let lines = [prompt + " " + q + "syntheticFirst" + q + ", " + q + next + q + ":", "syntheticSecond", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[0].contains(next))
        #expect(output[2] == "done")
    }

    @Test(arguments: ["device_code:", "user_code:", "Enter the code:", "Your code is:"], ["", "first"])
    func explicitCodeContinuationsKeepOpaqueValuesSecret(prompt: String, prefix: String) {
        let lines = [prompt + " " + prefix + "\\", "", "syntheticOpaqueCode", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output[0].contains("first"))
        #expect(output[1] == "")
        #expect(output[2] == "[redacted:device-code]")
        #expect(output[3] == "done")
        #expect(Redactor().redact(lines.joined(separator: "\n")) == output.joined(separator: "\n"))
    }

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
