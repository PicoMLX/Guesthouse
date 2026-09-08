import Testing
@testable import GuesthouseCore

@Suite struct RedactorAdjacentControlTests {
    @Test(arguments: ["\u{0}\u{0}", "\u{8}\u{8}", "\u{1B}]title\u{7}\u{0}", "\u{0}\u{1B}[31m"],
          ["Bearer syntheticCredential", "Basic dXNlcjpwYXNz", "sk-abcdefghijklmnopqrstuvwx"])
    func adjacentControlsRetainTheBoundaryBeforeCredentials(controls: String, token: String) {
        let result = Redactor.renderings(of: "filename" + controls + token)
        #expect(result.joined == "filename" + token)
        #expect(result.spliced == "filename" + Redactor.splicedBoundary + token)
    }

    @Test(arguments: ["\u{0}\u{0}", "\u{8}\u{8}", "\u{1B}]title\u{7}\u{0}", "\u{0}\u{1B}[31m"],
          [("Bearer synthetic", "Credential"), ("Basic dXNlcj", "pwYXNz"), ("sk-abcdefgh", "ijklmnopqrstuvwx")])
    func adjacentControlsKeepCredentialInteriorsWhole(controls: String, parts: (String, String)) {
        let result = Redactor.renderings(of: parts.0 + controls + parts.1)
        #expect(result.joined == parts.0 + parts.1)
        #expect(result.spliced == result.joined)
    }
}
