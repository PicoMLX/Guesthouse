import Testing
@testable import GuesthouseCore

@Test(arguments: ["HMAC-SHA256", "PBKDF2-HMAC-SHA256", "ECDSA-SHA256", "CHACHA20-POLY1305"])
func anUntrustedDeviceCodeCannotClaimAnAlgorithmExemption(value: String) {
    #expect(Redactor().redact(untrusted: value) == "[redacted:device-code]")
    #expect(Redactor().redact(fieldValue: value) == "[redacted:device-code]")
    #expect(Redactor().redact("supported code " + value) == "supported code " + value)
}
