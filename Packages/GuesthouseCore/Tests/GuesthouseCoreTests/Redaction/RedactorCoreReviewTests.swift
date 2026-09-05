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
