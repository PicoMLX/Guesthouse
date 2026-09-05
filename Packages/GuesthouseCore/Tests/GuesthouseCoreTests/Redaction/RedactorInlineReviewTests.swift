import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlineReviewTests {
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
