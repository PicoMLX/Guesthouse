import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlineReviewTests {
    @Test(arguments: [#"args: "--password opaqueCredential""#, #"["--password opaqueCredential"]"#,
                      "(--password opaqueCredential)", "{--token opaqueCredential}", "<--password opaqueCredential>"])
    func diagnosticFramesDoNotHideSecretOptions(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("opaqueCredential"))
    }

    @Test(arguments: ["\"--password", "[--token", "(--password", "{--password", "<--password"])
    func framedValuelessOptionsStillOwnTheirFollowingValue(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingSecretValue)
    }

    @Test(arguments: ["prefix--password opaqueCredential", "build/--password opaqueCredential", "file.--token opaqueCredential"])
    func identifierInteriorDashesDoNotBecomeOptions(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
    }

    @Test(arguments: ["Basic dXNl\\", "Digest username=sample, response=first\\", "Negotiate abcdefgh\\"])
    func partialAuthorizationValuesKeepTheirExplicitContinuation(_ input: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(output.contains("[redacted:"))
        #expect(!output.contains("dXNl") && !output.contains("first") && !output.contains("abcdefgh"))
        #expect(state.authorizationValueIsOnTheNextLine)
        #expect(state.authorizationValueExplicitlyContinues)
    }

    @Test(arguments: [#"["--password", ""\"#, #"["--password", "first" \"#])
    func serializedQuotedFragmentsRetainTheirContinuationTail(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingSecretValue && state.secretValueExplicitlyContinues)
    }

    @Test(arguments: [#"["--password", "", "--verbose"]"#, #"["--password", ""\\"#])
    func serializedSiblingAndEvenBackslashBoundariesStayClosed(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(!state.expectingSecretValue && !state.secretValueExplicitlyContinues)
    }

    @Test(arguments: [#"[\"--password\", \"opaqueCredential\"]"#, #"[\'--password\', \'opaqueCredential\']"#])
    func encodedOptionLabelsRetainTheirAdjacentCredential(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("opaqueCredential"))
    }

    @Test(arguments: ["Enter the code ABCD EFGH", "Paste the code 1234 5678"])
    func groupedImperativeCodesDoNotReleaseTheirFinalGroup(_ input: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(!output.contains("EFGH") && !output.contains("5678"))
    }

    @Test(arguments: ["Basic", "Basic \\", " basic \t\\ "])
    func valueLessBasicArmsTheNextRecord(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingAuthorizationValue)
        #expect(state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: [#"["--password", \"#, #"["--password", opaque\"#])
    func serializedContinuationKeepsItsPendingValue(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingSecretValue)
        #expect(state.secretValueExplicitlyContinues)
    }

    @Test func evenSerializedBackslashesDoNotExplicitlyContinue() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: #"["--password", \\"#, codeExpected: false, state: &state)
        #expect(!state.expectingSecretValue)
        #expect(!state.secretValueExplicitlyContinues)
    }

    @Test(arguments: ["password:", "Authorization:", "device_code:", "Your code is:"],
          [#"""opaqueCredential"#, #"'first'opaqueCredential"#, #"""opaqueCredential"unfinished"#])
    func adjacentQuotedFragmentsRemainOneSensitiveValue(label: String, value: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: label + " " + value, codeExpected: false, state: &state)
        #expect(!output.contains("opaqueCredential"))
        #expect(!output.contains("unfinished"))
    }

    @Test(arguments: ["Your code is", "Your one-time code is", "Your verification code is"],
          ["abcd efgh", "ABCD EFGH", "12 34"])
    func groupedDeclarativeCodesKeepAllGroupsSensitive(prompt: String, value: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: prompt + " " + value + ", valid for 15 minutes",
                                           codeExpected: false, state: &state)
        #expect(output == prompt + " [redacted:device-code], valid for 15 minutes")
    }

    @Test func rawMarkerTextCannotCertifyThatAnUntrustedFoldEnded() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "password: [redacted:secret]", codeExpected: false, state: &state)
        #expect(state.expectingSecretContinuation)
    }

    @Test func ordinaryBasicProseDoesNotAcquireAuthorizationState() {
        var state = Redactor.StreamState()
        let input = "Basic configuration is available"
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(!state.expectingAuthorizationValue)
    }
}
