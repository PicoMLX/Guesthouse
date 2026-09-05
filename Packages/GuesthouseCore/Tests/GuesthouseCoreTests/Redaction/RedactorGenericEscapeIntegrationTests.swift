import Testing
import GuesthouseCore

@Suite struct RedactorGenericEscapeIntegrationTests {
    @Test(arguments: ["\u{1B}", "\u{1B}("], ["accessToken", "Authorization", "user_code"])
    func recoveredLabelsProtectCurrentAndFollowingValues(escape: String, label: String) {
        let opener = String(label.prefix(1) + escape + label.dropFirst())
        let inline = Redactor().redact(opener + ": syntheticPassword")
        #expect(!inline.contains("syntheticPassword"))
        let lines = Redactor().redact(lines: [opener + ":", "syntheticPassword", "Finished"])
        #expect(!lines[1].text.contains("syntheticPassword"))
        #expect(lines[2].text == "Finished")
    }

    @Test(arguments: ["ghp_syntheticFirst", "sk-synthetic", "Bearer syntheticFirst"],
          ["\u{0}", "\u{0}\u{0}", "\u{1B}[31m"])
    func adjacentCredentialsAreBothHidden(prefix: String, controls: String) throws {
        let input = prefix + controls + "password: syntheticSecond"
        let output = Redactor().redact(input)
        #expect(!output.contains("synthetic"))
        let batch = try RedactedLines(redacting: [prefix + controls + "password:", "syntheticSecond", "Finished"])
        #expect(!batch.lines[0].text.contains("synthetic"))
        #expect(!batch.lines[1].text.contains("synthetic"))
        #expect(batch.lines[2].text == "Finished")
    }
}
