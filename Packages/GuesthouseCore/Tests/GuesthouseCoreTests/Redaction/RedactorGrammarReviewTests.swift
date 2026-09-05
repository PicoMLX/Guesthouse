import Testing
@testable import GuesthouseCore

@Suite struct RedactorGrammarReviewTests {
    @Test(arguments: ["Authorization:opaque", "Proxy-Authorization:opaque", "\"Authorization\":\"opaque\""])
    func authorizationDelimitersBoundLabelsWithoutWhitespace(input: String) {
        #expect(input.contains(Redactor.patterns.authorizationHeader))
        #expect(!"AuthorizationExtra:opaque".contains(Redactor.patterns.authorizationHeader))
    }

    @Test(arguments: ["device_code:first", "user_code:first", "\"device_code\":\"first\"", "'user_code':'first'"])
    func codeFieldDelimitersBoundLabelsWithoutWhitespace(input: String) throws {
        let match = try #require(input.firstMatch(of: Redactor.patterns.codeField))
        #expect(match.3.contains("first"))
    }

    @Test(arguments: ["device_codesecret:first", "user_codesecret:first"])
    func longerIdentifiersDoNotBecomeCodeFields(input: String) {
        #expect(!input.contains(Redactor.patterns.codeField))
    }

    @Test(arguments: ["--password", "--token", "--api-key", "--github-token"])
    func terminalSplicesRemainOptionBoundaries(option: String) {
        #expect(("filename\u{001F}" + option + " synthetic").contains(Redactor.patterns.secretOption))
        #expect(("filename\u{001F}" + option).contains(Redactor.patterns.secretOptionOnly))
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

    @Test(arguments: ["Enter the code shown below:", "Paste this code displayed below:", "Code:", " Code="])
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

    @Test(arguments: ["device code island", "user code arguably valid", "Enter the code shown below", "error code:42", "risk-averse-and-careful", "prefixsk-short", "sk- is a prefix"])
    func nearbyProseDoesNotBecomeADelimitedPrompt(input: String) {
        #expect(!input.contains(Redactor.patterns.codePrompt))
        #expect(!input.contains(Redactor.patterns.wrappedTokenAtLineEnd))
        #expect(!input.contains(Redactor.patterns.apiKey))
        #expect(!input.contains(Redactor.patterns.declarativeCodePrompt))
        #expect(!input.contains(Redactor.patterns.codePromptOnly))
    }

    @Test(arguments: ["your code is [redacted:device-code]", "Your one-time code is [redacted:device-code]"])
    func existingMarkersDoNotBecomePromptDelimiters(input: String) {
        #expect(!input.contains(Redactor.patterns.codePrompt))
        #expect(!input.contains(Redactor.patterns.codePromptOnly))
    }

    @Test(arguments: ["secret_key", "secretKey", "secret-key", "secret key", "password", "token"], [":", "="])
    func secretLabelsUseTheirDelimiterAsTheBoundary(label: String, delimiter: String) throws {
        let match = try #require((label + delimiter + "opaqueValue").firstMatch(of: Redactor.patterns.labeledSecret))
        #expect(match.2 == label)
        #expect(match.3 == "opaqueValue")
        #expect((label + delimiter).contains(Redactor.patterns.secretLabelOnly))
    }

    @Test(arguments: ["", "file.", " ", "_"], ["", "short", "abcdefghijklmnopqrst"])
    func genericWrappedKeysKeepTheirPrefixCapture(prefix: String, payload: String) throws {
        let input = prefix + "sk-" + payload
        #expect(try #require(input.firstMatch(of: Redactor.patterns.wrappedTokenAtLineEnd)).1 == "sk-")
        #expect(try #require(input.firstMatch(of: Redactor.patterns.apiKey)).2 == "sk-" + payload)
    }
}
