import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlineTests {
    @Test(arguments: [
        "run --github.token syntheticOpaque", #"["--github.token", "syntheticOpaque"]"#,
        #"{"api.key":"syntheticOpaque"}"#, "api.key: syntheticOpaque",
        "https://user:syntheticFirst@one/path,//user:syntheticSecond@two/path",
        #"{"url":"https://user:syntheticOpaque\u0040example.com/path"}"#
    ])
    func qualifiedFieldsAndEncodedURLValuesCannotExposeCredentials(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("synthetic"))
    }

    @Test(arguments: ["Digest username=", #"Digest username="closed", response="#,
                      "AWS4-HMAC-SHA256 Credential=", "Authorization: Digest username="])
    func terminalAuthorizationAssignmentsRequireTheNextValue(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: [(#"Digest username="syntheticFirst"#, 0), (#"AWS4-HMAC-SHA256 Credential="syntheticFirst"#, 0),
                      (#"Authorization: Digest username="syntheticFirst"#, 0), (#"Digest username=\"syntheticFirst"#, 1),
                      (#"Digest username="closed", response="syntheticFirst"#, 0)])
    func openAuthorizationParametersKeepTheirQuoteAndEnclosingFold(_ input: String, _ depth: Int) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("syntheticFirst"))
        #expect(state.quotedValue?.delimiter == "\"")
        #expect(state.quotedValue?.kind == "authorization")
        #expect(state.quotedValue?.escapeDepth == depth)
        #expect(state.quotedValue?.enclosingAuthorizationFold == true)
    }

    @Test(arguments: [#"Digest username="syntheticClosed""#, #"Authorization: "Digest username='syntheticClosed""#,
                      "NTLM dXNlcjpwYXNz=", #"Digest username="syntheticClosed=""#])
    func closedAuthorizationValuesDoNotRetainAnInnerQuote(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("syntheticClosed"))
        #expect(state.quotedValue == nil && !state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: ["Enter the code AB12CD34", "Your code is AB12CD34"])
    func codePromptBackslashesOutsideTheValueStillContinue(_ prompt: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: prompt + " \\", codeExpected: false, state: &state)
        #expect(state.expectingDeviceCode)
    }
    @Test(arguments: [("[AB", "]"), ("{AB", "}"), ("(AB", ")"), ("<AB", ">"), ("`AB", "`")])
    func unfinishedCodeFramesRetainTheirClosingDelimiter(_ value: String, _ closer: Character) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: "Enter the code " + value, codeExpected: false, state: &state)
            == "Enter the code [redacted:device-code]")
        #expect(state.quotedValue?.delimiter == closer && state.quotedValue?.kind == "device-code")
    }

    @Test func aTrailingDeviceCodeSeparatorAwaitsTheNextRecord() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "Your code is ABCD-", codeExpected: false, state: &state)
        #expect(state.expectingDeviceCode)
    }
    @Test(arguments: [("--pass", "word syntheticOpaque"), ("Set-Coo", "kie: session=syntheticOpaque"),
                      ("Authoriz", "ation: syntheticOpaque"), ("pass", "word: syntheticOpaque"),
                      ("--github-", "token syntheticOpaque"), ("--github.", "token syntheticOpaque"),
                      ("api.k", "ey: syntheticOpaque"), ("Bea", "rer syntheticOpaque"),
                      ("password", ": syntheticOpaque"), ("device_code", ": syntheticOpaque"),
                      ("gh", "p_syntheticOpaque"), ("gith", "ub_pat_syntheticOpaque"),
                      ("clientSec", "ret: syntheticOpaque"), ("refreshTo", "ken: syntheticOpaque"),
                      ("sessionTo", "ken: syntheticOpaque"), ("current_secret-ac", "cess_key: syntheticOpaque"),
                      ("sk", "-syntheticOpaque"), ("s", "k-syntheticOpaque")])
    func restoredLabelsExposeTheCompleteCredentialToInlineMatching(_ first: String, _ second: String) throws {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: first, codeExpected: false, state: &state)
        let restored = try #require(Redactor.restoringCredentialLabel(in: second, state: &state))
        #expect(state.pendingCredentialLabel == nil)
        #expect(!Redactor.applyPatterns(to: restored, codeExpected: false, state: &state).contains("syntheticOpaque"))
    }

    @Test(arguments: [#"{"url":"https://example.com"}"#, #"[{"url":"https://example.com"}]"#])
    func closedStructuredURLsKeepTheirPublicHost(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(!state.expectingURLUserInfo)
    }

    @Test(arguments: ["Basic", "Bearer", "NTLM", "Negotiate", "Digest", "AWS4-HMAC-SHA256"])
    func schemeOnlyHeadersAwaitAnUnindentedValue(_ scheme: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "Authorization: " + scheme, codeExpected: false, state: &state)
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: [#""AB""#, #""""#, "'a'", #"'AB'"#])
    func completedQuotedCodesDoNotAwaitAnotherValue(_ value: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "Enter the code " + value, codeExpected: false, state: &state)
        #expect(!state.expectingDeviceCode && !state.expectingDeviceCodeContinuation && state.quotedValue == nil)
    }

    @Test(arguments: [("--pass", "--pass"), ("run --github-to", "--to"), ("--api-", "--api-"), ("Set-Coo", "set-coo"), ("Co", "co")])
    func pendingLabelStateContainsOnlyBoundedStructure(_ input: String, _ expected: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.pendingCredentialLabel == expected)
        #expect(Redactor.partialCredentialLabel(in: "--" + String(repeating: "vendor", count: 10_000) + "-pass") == "--pass")
    }

    @Test(arguments: [#"Digest username="Mufasa","#, "AWS4-HMAC-SHA256 Credential=syntheticFirst,"])
    func parameterCommasArmAnUnindentedAuthorizationValue(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: [#""ABC123""#, "'ABC123'", "[ABC123]", "{ABC123}", "(ABC123)", "<ABC123>"])
    func framedDelimiterlessCodesRemainOpaque(_ value: String) {
        var state = Redactor.StreamState()
        let result = Redactor.applyPatterns(to: "Enter the code " + value + " at the URL shown", codeExpected: false, state: &state)
        #expect(result == "Enter the code [redacted:device-code] at the URL shown")
    }

    @Test(arguments: ["Digest user", "AWS4-HMAC-SHA256 Cred"])
    func partialParameterNamesArmAuthorization(_ input: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(output.hasSuffix("[redacted:authorization]"))
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: [("Bearer", "syntheticOpaque"), ("Basic", "dXNlcjpwYXNz"), ("NTLM", "TlRMTVNTUAABAAAA")])
    func literalMarkersCannotHideStandaloneAuthorization(_ scheme: String, _ value: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: scheme + " [redacted:decoy] " + value, codeExpected: false, state: &state)
        #expect(!output.contains(value))
        #expect(state.expectingAuthorizationValue)
    }

    @Test(arguments: ["password", "api.key", "Authorization", "device_code"], ["\"", "\\\""])
    func completeFieldsBoundInlineOwnership(label: String, quote: String) {
        var state = Redactor.StreamState()
        let input = label + ": " + quote + "synthetic" + quote + ", status: ready"
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(!output.contains("synthetic"))
        #expect(output.contains("status: ready"))
        #expect(!state.expectingSecretValue && !state.expectingAuthorizationValue && !state.expectingDeviceCode)
    }

    @Test(arguments: ["password:", "Authorization:", "device_code:"])
    func initialExplicitValuesArmTheirNextLine(_ label: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: label + " \"synthetic\" \\", codeExpected: false, state: &state)
        #expect(!output.contains("synthetic"))
        #expect(state.expectingSecretValue || state.authorizationValueIsOnTheNextLine || state.expectingDeviceCode)
    }

    @Test func ordinaryDiagnosticsStayUnchanged() {
        var state = Redactor.StreamState()
        let line = "process exited with code 1; status: ready"
        #expect(Redactor.applyPatterns(to: line, codeExpected: false, state: &state) == line)
    }
}
