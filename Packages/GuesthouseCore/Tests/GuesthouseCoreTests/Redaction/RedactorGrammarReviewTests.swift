import Testing
@testable import GuesthouseCore

@Suite struct RedactorGrammarReviewTests {
    @Test(arguments: ["--password", "--token", "--api-key", "--github-token"])
    func terminalSplicesRemainOptionBoundaries(option: String) {
        #expect(("filename\u{009F}" + option + " synthetic").contains(Redactor.patterns.secretOption))
        #expect(("filename\u{009F}" + option).contains(Redactor.patterns.secretOptionOnly))
    }

    @Test(arguments: ["remote=//sample:synthetic@example.com", "remote = //sample:synthetic@example.com",
                      "--remote=//sample:synthetic@example.com", "run -r=//sample:synthetic@example.com"])
    func assignedNetworkPathsRecognizeTheirUserinfo(input: String) throws {
        let match = try #require(input.firstMatch(of: Redactor.patterns.urlUserInfo))
        #expect(match.0.contains("synthetic"))
        #expect(!match.1.contains("synthetic"))
    }

    @Test(arguments: ["https://example.com?remote=//folder@archive", "https://example.com/path//folder@archive",
                      "https://example.com?--remote=//folder@archive", "https://example.com/path/-r=//folder@archive"])
    func embeddedPathsDoNotBecomeAssignmentValues(input: String) {
        #expect(!input.contains(Redactor.patterns.urlUserInfo))
    }

    @Test(arguments: ["Enter the code", "Paste this code", "Copy your code",
                      "Enter the code shown below:", "Paste this code displayed below:"])
    func valueLessImperativePromptsRetainContext(prompt: String) {
        #expect(prompt.contains(Redactor.patterns.codePromptOnly))
    }

    @Test(arguments: ["Enter the code shown below:", "Paste this code displayed below:"])
    func delimitedInstructionsStillCaptureInlineValues(prompt: String) throws {
        let match = try #require((prompt + " abcd").firstMatch(of: Redactor.patterns.codePrompt))
        #expect(match.1 == prompt)
        #expect(match.0.hasSuffix("abcd"))
    }

    @Test(arguments: ["Your device code is:", "Your user code is=", "device code equals : ", "user code reads = "])
    func delimitedDeclarationsCaptureOnlyTheirOpaqueValues(prompt: String) throws {
        let match = try #require((prompt + "abcd").firstMatch(of: Redactor.patterns.declarativeCodePrompt))
        #expect(match.2 == "abcd")
    }

    @Test(arguments: ["device code island", "user code arguably valid", "Enter the code shown below"])
    func nearbyProseDoesNotBecomeADelimitedPrompt(input: String) {
        #expect(!input.contains(Redactor.patterns.declarativeCodePrompt))
        #expect(!input.contains(Redactor.patterns.codePromptOnly))
    }

    @Test(arguments: ["your code is [redacted:device-code]", "Your one-time code is [redacted:device-code]"])
    func existingMarkersDoNotBecomePromptDelimiters(input: String) {
        #expect(!input.contains(Redactor.patterns.codePrompt))
        #expect(!input.contains(Redactor.patterns.codePromptOnly))
    }
}
