import Testing
@testable import GuesthouseCore

@Suite struct RedactorPhysicalAPIReviewTests {
    @Test func quotedClosingRecordsStillOpenPrivateKeyState() {
        let output = Redactor().redact(lines: [
            "password: \"", "-----BEGIN PRIVATE KEY-----\"", "syntheticKeyBody",
            "-----END PRIVATE KEY-----", "Finished"
        ]).map(\.text)
        #expect(!output.joined().contains("syntheticKeyBody"))
        #expect(!output[3].contains("END PRIVATE KEY"))
        #expect(output[4] == "Finished")
    }

    @Test(arguments: ["\u{1B}", "\u{1B}("])
    func recoveredIncompleteURLsProtectTheCurrentAndNextRecord(_ escape: String) {
        let output = Redactor().redact(lines: [
            "https" + escape + "://sample:syntheticPassword", "@example.com", "Finished"
        ]).map(\.text)
        #expect(!output.joined().contains("syntheticPassword"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [("eyJhbGciOiJIUzI1NiJ9.", "cGF5bG9hZA.c2lnbmF0dXJl"),
                      ("eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..", "aXY.c3ludGhldGlj.dGFn")])
    func compactJOSERecordsCannotReconstructACredential(_ parts: (String, String)) {
        let output = Redactor().redact(lines: [parts.0, parts.1, "[status] Finished"]).map(\.text)
        #expect(!output[0].contains("eyJ"))
        #expect(!output[1].contains(parts.1))
        #expect(output[2] == "[status] Finished")
    }

    @Test(arguments: ["device_code: ABCD", "Enter the code: ABCD", "Your code is ABCD"])
    func ordinaryCodeFoldsEndAtANewUnindentedDiagnostic(_ opener: String) {
        let output = Redactor().redact(lines: [opener, " EFGH", " IJKL", "Finished", "  details"]).map(\.text)
        #expect(!output.joined().contains("EFGH"))
        #expect(!output.joined().contains("IJKL"))
        #expect(output[3] == "Finished")
        #expect(output[4] == "  details")
    }

    @Test func aMissingDeviceCodeCanSpanSeveralIndentedFragments() {
        let output = Redactor().redact(lines: ["device_code:", " ABCD-", " EFGH", "Finished"]).map(\.text)
        #expect(!output.joined().contains("ABCD"))
        #expect(!output.joined().contains("EFGH"))
        #expect(output[3] == "Finished")
    }

    @Test(arguments: [("Basic dXNlcj", " pwYXNz"), ("Bearer", " syntheticBearerToken")])
    func partialAuthorizationSchemesProtectTheirPublicContinuation(_ parts: (String, String)) {
        let output = Redactor().redact(lines: [parts.0, parts.1, "Finished"]).map(\.text)
        #expect(output[1] == "[redacted:authorization]")
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["device_code: ABCD, password:", "Authorization: Bearer abc, password:"])
    func pendingSiblingFieldsProtectTheirFollowingPublicValue(_ opener: String) {
        let output = Redactor().redact(lines: [opener, "syntheticSecret", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticSecret"))
        #expect(output[2] == "Finished")
    }

    @Test func aURLContinuationCannotConsumeALaterSecretLabel() {
        let output = Redactor().redact(lines: [
            "https://sample:syntheticFirst", "password: syntheticSecond", "Finished"
        ]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["password", "Authorization", "device_code"])
    func unrelatedSuffixBackslashesCannotContinueAClosedCredential(_ label: String) {
        let output = Redactor().redact(lines: [
            label + ": \"syntheticFirst",
            "syntheticSecond\" --verbose \\",
            "Finished", "  diagnostic details"
        ]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "Finished")
        #expect(output[3] == "  diagnostic details")
    }

    @Test(arguments: ["password:", "authorization:", "user_code:", "--password"],
          ["\u{1B}", "\u{1B}[31"])
    func recoveredOpenersProtectTheirCurrentAndFollowingValues(label: String, escape: String) {
        let opener = escape + label
        #expect(!Redactor().redact(opener + " syntheticOpaque").contains("syntheticOpaque"))
        let output = Redactor().redact(lines: [opener, "syntheticOpaque", "[status] Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output[2] == "[status] Finished")
    }

    @Test func restoredPEMBeginOwnsLaterRecords() {
        let output = Redactor().redact(lines: [
            "-----\u{1B}BEGIN PRIVATE KEY-----syntheticFirst",
            "syntheticSecond", "-----END PRIVATE KEY-----", "Finished"
        ]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[3] == "Finished")
    }

    @Test func standaloneBearerFoldDoesNotReleaseIndentedFragments() {
        let output = Redactor().redact(lines: [
            "Bearer syntheticFirst", "  syntheticSecond", "\tthirdFragment", "Finished"
        ]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(!output.joined().contains("thirdFragment"))
        #expect(output[3] == "Finished")
    }
}
