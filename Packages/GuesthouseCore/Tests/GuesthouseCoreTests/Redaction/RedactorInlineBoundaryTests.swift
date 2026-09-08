import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlineBoundaryTests {
    @Test(arguments: [
        ("--password [redacted:decoy] publicArgument", "--password [redacted:secret] publicArgument"),
        (#"["--password", "[redacted:decoy]", "publicArgument"]"#, #"["--password", [redacted:secret], "publicArgument"]"#)
    ])
    func literalMarkersReceiveNoSpecialTrustOrExtraArgumentOwnership(_ input: String, _ expected: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == expected)
        #expect(state.quotedValue == nil && !state.expectingSecretValue && !state.secretValueExplicitlyContinues)
        #expect(!state.expectingAuthorizationValue && !state.authorizationValueIsOnTheNextLine)
        #expect(!state.expectingSecretContinuation)
    }

    @Test(arguments: [("password", true, false), ("Authorization", false, true), ("device_code", false, false)], [#""[redacted:decoy]" syntheticOpaque"#, #"'syntheticFirst' syntheticOpaque"#])
    func unframedTextAfterAQuotedFieldIsStillPartOfItsValue(_ field: (String, Bool, Bool), _ value: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: field.0 + ": " + value, codeExpected: false, state: &state)
        #expect(!output.contains("syntheticOpaque") && !output.contains("syntheticFirst") && !output.contains("decoy"))
        #expect(state.expectingSecretContinuation == field.1)
        #expect(state.expectingAuthorizationValue == field.2)
        #expect(state.expectingDeviceCodeContinuation == (field.0 == "device_code"))
        #expect(!state.expectingSecretValue && !state.secretValueExplicitlyContinues)
        #expect(!state.authorizationValueIsOnTheNextLine && !state.authorizationValueExplicitlyContinues)
        #expect(!state.expectingDeviceCode)
    }

    @Test(arguments: ["HMAC-SHA256", "ECDSA-SHA512", "RSA-SHA256", "PBKDF2-HMAC-SHA256", "CHACHA20-POLY1305"])
    func incidentalAlgorithmNamesAreNotPromptedCodes(_ algorithm: String) {
        var state = Redactor.StreamState()
        let input = "process exited with code " + algorithm
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(!state.expectingDeviceCode && !state.expectingDeviceCodeContinuation)
        #expect(!Redactor.applyPatterns(to: "device_code: " + algorithm, codeExpected: false, state: &state).contains(algorithm))
    }

    @Test(arguments: ["HMAC-SHA256", "ECDSA-SHA512", "CHACHA20-POLY1305"])
    func pendingCodeShapeMatchingDoesNotPreserveAlgorithms(_ value: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: value, codeExpected: true, state: &state).contains(value))
    }

    @Test(arguments: [(#"password: "syntheticOpaque" , status: ready"#, "password: [redacted:secret] , status: ready"),
                      (#"Authorization: "syntheticOpaque" , status: ready"#, "Authorization: [redacted:authorization] , status: ready")])
    func realQuotedFieldSeparatorsStillPreserveSiblingDiagnostics(_ input: String, _ expected: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == expected)
        #expect(state.quotedValue == nil && !state.expectingSecretContinuation && !state.expectingAuthorizationValue)
    }

    @Test(arguments: ["Bearer", "Basic", "Digest", "NTLM", "Negotiate", "AWS4-HMAC-SHA256"])
    func literalMarkersDoNotCompleteAnAuthorizationValue(_ scheme: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: scheme + " [redacted:decoy]", codeExpected: false, state: &state)
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: ["Digest realm", "Digest USER", "AWS4-HMAC-SHA256 Signed", "AWS4-HMAC-SHA256 Sign"])
    func knownParameterPrefixesAwaitTheirRemainder(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state).hasSuffix("[redacted:authorization]"))
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: ["Digest summary", "AWS4-HMAC-SHA256 guide", "Basic architecture works"])
    func ordinarySchemeProseArmsNeitherAuthorizationFlag(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(!state.expectingAuthorizationValue && !state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: [2, 3, 16, 256])
    func nestedSlashEscapesKeepCompleteAndContinuedUserInfoPrivate(_ depth: Int) {
        let slash = String(repeating: "\\", count: depth) + "/"
        let prefix = "https:" + slash + slash
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: prefix + "user:syntheticOpaque@example.com/path", codeExpected: false, state: &state)
            == prefix + "[redacted:userinfo]@example.com/path")
        #expect(!state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: prefix + "user:syntheticFirst", codeExpected: false, state: &state)
            == prefix + "[redacted:userinfo]")
        #expect(state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: "syntheticSecond@example.com/path", codeExpected: false, state: &state)
            == "[redacted:userinfo]@example.com/path")
        #expect(!state.expectingURLUserInfo)
    }

    @Test(arguments: [("(", ")"), ("'", "'")], ["user:opaque", "example.com:443"])
    func apparentFramesCannotReleaseAValidUserinfoContinuation(frame: (String, String), authority: String) {
        var state = Redactor.StreamState()
        let first = Redactor.applyPatterns(to: frame.0 + "https://" + authority + frame.1, codeExpected: false, state: &state)
        #expect(first == frame.0 + "https://[redacted:userinfo]")
        #expect(state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: "@example.com/path", codeExpected: false, state: &state)
                == "[redacted:userinfo]@example.com/path")
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    @Test(arguments: ["ghp", "gho", "ghu", "ghs", "ghr", "github_pat"])
    func completeProviderStemsAwaitTheirUnderscore(_ stem: String) throws {
        var state = Redactor.StreamState()
        #expect(stem.contains(Redactor.patterns.wrappedTokenAtLineEnd))
        #expect(Redactor.applyPatterns(to: stem, codeExpected: false, state: &state) == "[redacted:github-token]")
        #expect(state.pendingCredentialLabel == stem)
        let restored = try #require(Redactor.restoringCredentialLabel(in: "_syntheticOpaque", state: &state))
        #expect(Redactor.applyPatterns(to: restored, codeExpected: false, state: &state) == "[redacted:github-token]")
    }

    @Test(arguments: ["Basic", "Digest", "NTLM", "Negotiate", "AWS4-HMAC-SHA256"])
    func bareAuthorizationSchemesAwaitTheirPhysicalValue(_ scheme: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: scheme, codeExpected: false, state: &state)
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: [":/", ":\\/"])
    func colonSlashFragmentsRetainAuthorityState(_ fragment: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: fragment, codeExpected: false, state: &state)
        #expect(state.pendingURLSlashes == 1)
        #expect(!Redactor.applyPatterns(to: "/user:syntheticOpaque@example.com", codeExpected: false, state: &state).contains("syntheticOpaque"))
    }

    @Test(arguments: [("Basic d", "Basic [redacted:authorization]"),
                      ("NTLM T", "NTLM [redacted:authorization]"),
                      ("Negotiate Y", "Negotiate [redacted:authorization]")])
    func shortAuthorizationPayloadsAreConcealedAndRetained(_ input: String, _ expected: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(output == expected)
        #expect(state.expectingAuthorizationValue && state.authorizationValueIsOnTheNextLine)
    }

    @Test(arguments: ["Enter the code A", "Enter the code 12", "Enter the code B3"])
    func shortPromptCandidatesAreConcealedAndRetained(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == "Enter the code [redacted:device-code]")
        #expect(state.expectingDeviceCode)
        #expect(state.expectingDeviceCodeContinuation)
    }

    @Test(arguments: [#"[\"--password\""#, #"["--password""#])
    func serializedOptionsAwaitTheirSplitComma(_ input: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(state.expectingSecretValue)
    }

    @Test(arguments: ["[redacted:device-code]", "[redacted:secret] [redacted:device-code]"])
    func literalMarkersDoNotEndCodePromptRecognition(_ marker: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: "Enter the code " + marker + " ABC123", codeExpected: false, state: &state).contains("ABC123"))
        #expect(state.expectingDeviceCodeContinuation)
    }

    @Test(arguments: [#"{\\"password\\":\\"synthetic\\"}"#, #"{\\"Authorization\\":\\"synthetic\\"}"#])
    func encodedFieldKeysIdentifyTheirValues(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("synthetic"))
    }



    @Test(arguments: ["Cookie: session=syntheticOpaque", "Set-Cookie: session=syntheticOpaque; HttpOnly"])
    func cookieHeadersConcealTheWholeSessionValue(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("syntheticOpaque"))
    }

    @Test func completedEncodedContainersDoNotArmAnInnerField() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: #""\"{\\\"password\\\":\"""#, codeExpected: false, state: &state)
        #expect(!state.expectingSecretValue && state.quotedValue == nil)
        #expect(!state.expectingSecretContinuation)
    }

    @Test(arguments: ["password", "Authorization", "device_code", "Cookie", "Set-Cookie"], [2, 3, 16, 256])
    func multiplyEncodedCredentialKeysRemainVisibleToMatching(_ label: String, _ depth: Int) {
        let quote = String(repeating: "\\", count: depth) + "\""
        var state = Redactor.StreamState()
        let input = "{" + quote + label + quote + ":" + quote + "syntheticOpaque" + quote + "}"
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("syntheticOpaque"))
        #expect(state.quotedValue == nil)
        #expect(!state.expectingSecretValue && !state.expectingSecretContinuation && !state.secretValueExplicitlyContinues)
        #expect(!state.expectingAuthorizationValue && !state.authorizationValueIsOnTheNextLine && !state.authorizationValueExplicitlyContinues)
        #expect(!state.expectingDeviceCode && !state.expectingDeviceCodeContinuation)
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
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(output.contains("[redacted:device-code]") && !output.contains("ABCD"))
        #expect(state.expectingDeviceCodeContinuation)
        #expect(!state.expectingDeviceCode)
    }

    @Test(arguments: ["command: \u{60}", "run --verbose;", "options=[--verbose,"])
    func commandSeparatorsCannotHideOptions(_ prefix: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: prefix + "--password opaqueCredential", codeExpected: false, state: &state).contains("opaqueCredential"))
        #expect(!state.expectingSecretValue)
        state = Redactor.StreamState()
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
        #expect(state.quotedValue == nil && !state.expectingSecretValue)
        #expect(!state.expectingSecretContinuation && !state.secretValueExplicitlyContinues)
    }

    @Test(arguments: ["password", "Authorization", "device_code"], [")", ">"])
    func closingFramesBoundACompletedQuotedValue(_ label: String, _ frame: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: label + ": \"opaqueCredential\"" + frame, codeExpected: false, state: &state)
        #expect(output.contains("[redacted:") && !output.contains("opaqueCredential"))
        #expect(!state.expectingSecretContinuation)
        #expect(!state.expectingAuthorizationValue)
        #expect(!state.expectingDeviceCode)
        #expect(!state.expectingDeviceCodeContinuation)
        #expect(state.quotedValue == nil)
    }

    @Test(arguments: [("password: opaqueCredential", [true, false, false]),
                      ("Authorization: opaqueCredential", [false, true, false]),
                      ("device_code: opaqueCredential", [false, false, true])])
    func originalFieldsSurviveAnActiveURLContinuation(_ input: String, _ continuation: [Bool]) {
        var state = Redactor.StreamState()
        state.expectingURLUserInfo = true
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("opaqueCredential"))
        #expect([state.expectingSecretContinuation, state.expectingAuthorizationValue,
                 state.expectingDeviceCodeContinuation] == continuation)
    }

    @Test(arguments: ["device_code: ABCD, password:", "Authorization: Bearer abc, password:"])
    func originalPendingSiblingsRetainTheirNextValue(_ input: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(output.contains("[redacted:") && !output.contains("ABCD") && !output.contains("abc"))
        #expect(state.expectingSecretValue)
    }

    @Test(arguments: ["Basic dXNlcj", "Basic dXNl", "Basic dX"])
    func partialBasicAtTheRecordEndRetainsItsFold(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == "Basic [redacted:authorization]")
        #expect(state.expectingAuthorizationValue)
        #expect(state.authorizationValueIsOnTheNextLine)
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

    @Test func ambiguousCommaAuthoritiesAreConcealedEvenInsideQueries() {
        var state = Redactor.StreamState()
        // A comma + network-path authority may be a diagnostic-list separator or
        // a nested URL in a query. Neither interpretation proves its userinfo public.
        let input = "https://example.com/path?next=,//user:ordinary@host"
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
            == "https://example.com/path?next=,//[redacted:userinfo]")
        #expect(state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: "/path", codeExpected: false, state: &state) == "[redacted:userinfo]/path")
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    @Test(arguments: ["https://example.com/path//user:ordinary@host",
                      "https://example.com/path?next=path//user:ordinary@host",
                      "urls=[https://example.com/path//user:ordinary@host]"])
    func URLPathAndQuerySlashPairsRemainOrdinary(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
    }
}
