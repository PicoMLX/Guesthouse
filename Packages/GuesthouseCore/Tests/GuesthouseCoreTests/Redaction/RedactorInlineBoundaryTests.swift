import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlineBoundaryTests {
    @Test func completedEncodedContainersDoNotArmAnInnerField() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: #""\"{\\\"password\\\":\"""#, codeExpected: false, state: &state)
        #expect(!state.expectingSecretValue && state.quotedValue == nil)
    }

    @Test(arguments: ["password", "Authorization", "device_code", "Cookie", "Set-Cookie"], [2, 3, 16, 256])
    func multiplyEncodedCredentialKeysRemainVisibleToMatching(_ label: String, _ depth: Int) {
        let quote = String(repeating: "\\", count: depth) + "\""
        var state = Redactor.StreamState()
        let input = "{" + quote + label + quote + ":" + quote + "syntheticOpaque" + quote + "}"
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("syntheticOpaque"))
    }

    @Test func delimiterSlashesCanArriveOnSeparateRecords() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "https:", codeExpected: false, state: &state)
        _ = Redactor.applyPatterns(to: "/", codeExpected: false, state: &state)
        _ = Redactor.applyPatterns(to: " ", codeExpected: false, state: &state)
        #expect(!Redactor.applyPatterns(to: "/user:syntheticOpaque@host", codeExpected: false, state: &state).contains("syntheticOpaque"))
    }


    @Test(arguments: ["device_code: ABCD", "Enter the code: ABCD", "Your code is ABCD"])
    func nonemptyCodesRetainOnlyAnOrdinaryFold(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingDeviceCodeContinuation)
        #expect(!state.expectingDeviceCode)
    }

    @Test(arguments: ["command: \u{60}", "run --verbose;", "options=[--verbose,"])
    func commandSeparatorsCannotHideOptions(_ prefix: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: prefix + "--password opaqueCredential", codeExpected: false, state: &state).contains("opaqueCredential"))
        _ = Redactor.applyPatterns(to: prefix + "--password", codeExpected: false, state: &state)
        #expect(state.expectingSecretValue)
    }

    @Test(arguments: ["--device-code", "--user-code"])
    func opaqueCodesAreSecretArguments(_ option: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: "tool " + option + " opaqueCredential", codeExpected: false, state: &state).contains("opaqueCredential"))
        #expect(!Redactor.applyPatterns(to: "[\"" + option + "\", \"opaqueCredential\"]", codeExpected: false, state: &state).contains("opaqueCredential"))
    }

    @Test(arguments: [2, 3, 16, 256])
    func encodedArgvAdjacencySurvivesEveryEscapeDepth(_ depth: Int) {
        let quote = String(repeating: "\\", count: depth) + "\""
        var state = Redactor.StreamState()
        let input = "[" + quote + "--password" + quote + ", " + quote + "opaqueCredential" + quote + "]"
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("opaqueCredential"))
    }

    @Test(arguments: ["password", "Authorization", "device_code"], [")", ">"])
    func closingFramesBoundACompletedQuotedValue(_ label: String, _ frame: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: label + ": \"opaqueCredential\"" + frame, codeExpected: false, state: &state)
        #expect(!state.expectingSecretContinuation)
        #expect(!state.expectingAuthorizationValue)
        #expect(!state.expectingDeviceCode)
    }

    @Test(arguments: ["password: opaqueCredential", "Authorization: opaqueCredential", "device_code: opaqueCredential"])
    func originalFieldsSurviveAnActiveURLContinuation(_ input: String) {
        var state = Redactor.StreamState()
        state.expectingURLUserInfo = true
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("opaqueCredential"))
    }

    @Test(arguments: ["device_code: ABCD, password:", "Authorization: Bearer abc, password:"])
    func originalPendingSiblingsRetainTheirNextValue(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingSecretValue)
    }

    @Test(arguments: ["Basic dXNlcj", "Basic dXNl", "Basic dX"])
    func partialBasicAtTheRecordEndRetainsItsFold(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("[redacted:authorization]"))
        #expect(state.expectingAuthorizationValue)
    }

    @Test func missingBearerValueArmsAuthorizationState() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "Bearer", codeExpected: false, state: &state)
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test func delimitedNetworkPathURLsProtectEveryListElement() {
        var state = Redactor.StreamState()
        let result = Redactor.applyPatterns(to: "urls=[//user:syntheticFirst@host,//user:syntheticSecond@host]", codeExpected: false, state: &state)
        #expect(!result.contains("syntheticFirst"))
        #expect(!result.contains("syntheticSecond"))
    }

    @Test(arguments: ["https://example.com/path//user:ordinary@host",
                      "https://example.com/path?next=,//user:ordinary@host",
                      "urls=[https://example.com/path//user:ordinary@host]"])
    func URLPathAndQuerySlashPairsRemainOrdinary(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
    }
}
