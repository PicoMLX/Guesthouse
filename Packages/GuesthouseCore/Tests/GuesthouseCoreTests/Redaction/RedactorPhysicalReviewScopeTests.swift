import Testing
@testable import GuesthouseCore

@Suite struct RedactorPhysicalReviewScopeTests {
    @Test(arguments: [
        ("eyJhbGciOiJIUzI1NiJ9", ".cGF5bG9hZA.c2lnbmF0dXJl", "jwt"),
        ("ghp_", "syntheticPayload", "github-token"),
        ("ghp", "_syntheticPayload", "github-token"),
        ("github_pat_", "syntheticPayload", "github-token"),
        ("github_pat", "_syntheticPayload", "github-token"),
        ("sk-", "syntheticPayload", "api-key")
    ], [" ", "\t"])
    func paddingCannotReleaseWrappedCredentialRecords(_ parts: (String, String, String), _ padding: String) {
        let (header, continuation, kind) = parts
        let output = Redactor().redact(lines: [header + padding, continuation + padding,
            "syntheticFinalTail", "[status] Finished"]).map(\.text)
        #expect(!output[0].contains(header))
        #expect(!output[1].contains(continuation))
        #expect(output[2] == "[redacted:\(kind)]")
        #expect(output[3] == "[status] Finished")
    }

    @Test(arguments: ["\u{1B}", "\u{1B}[31", "\u{9B}31"])
    func recoveredPEMBeginsInsideAClosingQuotedValue(_ control: String) {
        let output = Redactor().redact(lines: ["password: \"", "-----" + control + "BEGIN PRIVATE KEY-----\"",
            "syntheticKeyBody", "-----END PRIVATE KEY-----", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticKeyBody"))
        #expect(output[3] == "[redacted:private-key]")
        #expect(output[4] == "Finished")
    }

    @Test(arguments: ["\u{1B}", "\u{1B}[31", "\u{9B}31"])
    func recoveredJOSEHeadersArmTheirPhysicalContinuation(_ control: String) {
        let output = Redactor().redact(lines: ["eyJhbGc" + control + "iOiJIUzI1NiJ9.",
            "cGF5bG9hZA.c2lnbmF0dXJl", "[status] Finished"]).map(\.text)
        #expect(!output[0].contains("JhbGc"))
        #expect(output[1] == "[redacted:jwt]")
        #expect(output[2] == "[status] Finished")
    }

    @Test(arguments: [
        ("eyJhbGciOiJIUzI1NiJ9", ".payload.syntheticSignature"),
        ("eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0", ".key.iv.cipher.syntheticTag")
    ])
    func theFinalJOSESegmentCanItselfWrapAfterItsRequiredDots(_ header: String, _ continuation: String) {
        let output = Redactor().redact(lines: [header, continuation, "syntheticFinalSegmentTail",
            "[status] Finished", "Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(Array(output.suffix(2)) == ["[status] Finished", "Finished"])
    }

    @Test(arguments: ["Digest", "NTLM", "Negotiate", "AWS4-HMAC-SHA256"])
    func bareSchemesOwnTheirFollowingCredentialRecord(_ scheme: String) {
        let output = Redactor().redact(lines: [scheme, " syntheticCredential", "Finished"]).map(\.text)
        #expect(output[1] == "[redacted:authorization]")
        #expect(output[2] == "Finished")
    }
}
