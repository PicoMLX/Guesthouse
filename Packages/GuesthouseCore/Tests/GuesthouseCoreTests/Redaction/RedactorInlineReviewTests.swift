import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlineReviewTests {

    @Test(arguments: ["args=--password", "command:--token", "args=--github-token"])
    func assignmentDelimitedOptionsKeepTheirValueContext(_ prefix: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: prefix + " opaqueCredential", codeExpected: false, state: &state).contains("opaqueCredential"))
        #expect(!state.expectingSecretValue)
        state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: prefix, codeExpected: false, state: &state)
        #expect(state.expectingSecretValue)
    }

    @Test(arguments: ["123 456", "12 34", "1 2 3 4", "ABC DEF", "A BC D", "12 ab34"])
    func imperativeCodeLengthCountsTheWholeGroupedValue(_ value: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: "Enter the code " + value + ", then continue", codeExpected: false, state: &state)
                == "Enter the code [redacted:device-code], then continue")
    }

    @Test(arguments: ["Enter the code 1 2", "Enter the code A B"])
    func shortGroupedEndOfRecordCandidatesRemainPending(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == "Enter the code [redacted:device-code]")
        #expect(state.expectingDeviceCode)
        #expect(state.expectingDeviceCodeContinuation)
    }

    @Test(arguments: ["Enter the code shown below", "Enter the code A B then continue",
                      "Enter the code 1 2 then continue"])
    func shortGroupedDiagnosticProseDoesNotBecomeAPendingCode(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(!state.expectingDeviceCode && !state.expectingDeviceCodeContinuation)
    }
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
        #expect(state.expectingAuthorizationValue)
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
        #expect(state.quotedValue == nil)
    }

    @Test(arguments: [#"[\"--password\", \"opaqueCredential\"]"#, #"[\'--password\', \'opaqueCredential\']"#])
    func encodedOptionLabelsRetainTheirAdjacentCredential(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("opaqueCredential"))
    }

    @Test(arguments: [("Enter the code ABCD EFGH", "Enter the code [redacted:device-code]"),
                      ("Paste the code 1234 5678", "Paste the code [redacted:device-code]")])
    func groupedImperativeCodesDoNotReleaseTheirFinalGroup(_ input: String, _ expected: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(output == expected)
    }

    @Test(arguments: [("Basic", false), ("Basic \\", true), (" basic \t\\ ", true)])
    func valueLessBasicArmsTheNextRecord(_ input: String, _ explicit: Bool) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingAuthorizationValue)
        #expect(state.authorizationValueIsOnTheNextLine)
        #expect(state.authorizationValueExplicitlyContinues == explicit)
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

    @Test(arguments: [("password:", "password: [redacted:secret]"),
                      ("Authorization:", "Authorization: [redacted:authorization]"),
                      ("device_code:", "device_code: [redacted:device-code]"),
                      ("Your code is:", "Your code is: [redacted:device-code]")],
          [#"""opaqueCredential"#, #"'first'opaqueCredential"#, #"""opaqueCredential"unfinished"#])
    func adjacentQuotedFragmentsRemainOneSensitiveValue(label: (String, String), value: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: label.0 + " " + value, codeExpected: false, state: &state)
        #expect(output == label.1)
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
