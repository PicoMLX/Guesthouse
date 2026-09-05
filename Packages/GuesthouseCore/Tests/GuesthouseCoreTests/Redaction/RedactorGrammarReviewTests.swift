import Testing
@testable import GuesthouseCore

@Suite struct RedactorGrammarReviewTests {
    @Test(arguments: ["--password", "--token", "--api-key", "--github-token"])
    func terminalSplicesRemainOptionBoundaries(option: String) {
        #expect(("filename\u{009F}" + option + " synthetic").contains(Redactor.patterns.secretOption))
        #expect(("filename\u{009F}" + option).contains(Redactor.patterns.secretOptionOnly))
    }

    @Test(arguments: ["remote=//sample:synthetic@example.com", "remote = //sample:synthetic@example.com"])
    func assignedNetworkPathsRecognizeTheirUserinfo(input: String) throws {
        let match = try #require(input.firstMatch(of: Redactor.patterns.urlUserInfo))
        #expect(match.0.contains("synthetic"))
        #expect(!match.1.contains("synthetic"))
    }

    @Test(arguments: ["https://example.com?remote=//folder@archive", "https://example.com/path//folder@archive"])
    func embeddedPathsDoNotBecomeAssignmentValues(input: String) {
        #expect(!input.contains(Redactor.patterns.urlUserInfo))
    }

    @Test(arguments: ["Enter the code", "Paste this code", "Copy your code"])
    func valueLessImperativePromptsRetainContext(prompt: String) {
        #expect(prompt.contains(Redactor.patterns.codePromptOnly))
    }

    @Test(arguments: ["your code is [redacted:device-code]", "Your one-time code is [redacted:device-code]"])
    func existingMarkersDoNotBecomePromptDelimiters(input: String) {
        #expect(!input.contains(Redactor.patterns.codePrompt))
        #expect(!input.contains(Redactor.patterns.codePromptOnly))
    }
}
