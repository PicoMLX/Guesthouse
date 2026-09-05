import Testing
@testable import GuesthouseCore

@Test(arguments: [
    ["Enter the code", "reviewValue", "done"],
    ["Authorization: Bearer \\", "reviewValue", "done"],
    ["Authorization: Basic first", "  continued\\", "reviewValue", "done"],
])
func explicitCredentialContinuationsRemainSensitive(_ lines: [String]) {
    #expect(!Redactor().redact(lines: lines).map(\.text).joined().contains("reviewValue"))
}

@Test func sanitizedCodeMarkersRemainStable() {
    #expect(Redactor().redact(untrusted: "your code is [redacted:device-code]") == "your code is [redacted:device-code]")
}

@Test(arguments: ["device_code:", "Your code is:", "Your code is"], ["\"", "\\\""])
func completedCodeFieldsRetainAlternateCodeContext(prompt: String, quote: String) {
    let output = Redactor().redact(prompt + " " + quote + "syntheticFirst" + quote + ", alternate: AB12-CD34")
    #expect(!output.contains("syntheticFirst"))
    #expect(!output.contains("AB12-CD34"))
}

@Test(arguments: ["--password", "--token", "--api-key", "--github-token"], [" ", "="])
func terminalBoundariesDoNotHideSecretOptions(option: String, separator: String) {
    let input = "filename\u{1B}[31m" + option + separator + "syntheticSecret --verbose"
    let output = Redactor().redact(input)
    #expect(!output.contains("syntheticSecret"))
    #expect(output.hasSuffix(" --verbose"))
    #expect(!Redactor().redact(lines: ["filename\u{1B}[31m" + option, "syntheticSecret"]).map(\.text).joined().contains("syntheticSecret"))
}
