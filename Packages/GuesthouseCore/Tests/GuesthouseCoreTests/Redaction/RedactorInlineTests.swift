import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlineTests {
    @Test(arguments: [("[AB", "]"), ("(AB", ")"), ("<AB", ">"), ("`AB", "`")])
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
                      ("--github-", "token syntheticOpaque"), ("Bea", "rer syntheticOpaque"),
                      ("password", ": syntheticOpaque"), ("device_code", ": syntheticOpaque"),
                      ("gh", "p_syntheticOpaque"), ("gith", "ub_pat_syntheticOpaque")])
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

    @Test(arguments: [#""ABC123""#, "'ABC123'", "[ABC123]", "(ABC123)", "<ABC123>"])
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

    @Test(arguments: ["password", "Authorization", "device_code"], ["\"", "\\\""])
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
