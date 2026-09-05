import Testing
@testable import GuesthouseCore

@Suite struct RedactorPromptReviewTests {
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
