import Testing
@testable import GuesthouseCore

@Suite struct RedactorPhysicalAPIReviewTests {
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
