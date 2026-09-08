import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactorStructuredKeyTests {
    @Test(arguments: [1, 128, 2_048])
    func transportEscapedRecordsNormalizeWithoutRescanningUnclosedQuotes(_ count: Int) {
        let input = Array(repeating: #"\"pass\u0077ord\":\"opaque\""#, count: count).joined(separator: ", ")
        let expected = Array(repeating: #"\"password\":\"opaque\""#, count: count).joined(separator: ", ")
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == expected)
    }

    @Test(arguments: [
        (#""pass\u0077ord:"syntheticOpaque""#, #""secret":"syntheticOpaque""#),
        (#"{'pass\u0077ord':'syntheticOpaque'}"#, #"{'password':'syntheticOpaque'}"#),
        (#"INFO "pass\u0077ord":"syntheticOpaque""#, #"INFO "password":"syntheticOpaque""#),
        (#"INFO 'pass\u0077ord'='syntheticOpaque'"#, #"INFO 'password'='syntheticOpaque'"#),
        (#"'pass\u0077ord:'syntheticOpaque'"#, #"'secret':'syntheticOpaque'"#)
    ])
    func diagnosticAndMalformedKeyBoundariesNormalize(_ input: String, _ expected: String) {
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == expected)
    }

    @Test(arguments: [1, 128, 2_048])
    func wideRecordsPreserveValuesAndNormalizeEveryEncodedKey(_ count: Int) {
        let prefix = (0..<count).map { "\"field\($0)\":\"visible\",\"pass\\u0077ord\":\"opaque\"" }.joined(separator: ",")
        let input = "{" + prefix + #", "message":"{\"pass\\u0077ord\":\"visible\"}"}"#
        let expected = "{" + prefix.replacingOccurrences(of: #""pass\u0077ord":"opaque""#, with: #""password":"opaque""#)
            + #", "message":"{\"pass\\u0077ord\":\"visible\"}"}"#
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == expected)
    }

    @Test func incompleteEncodedKeysRetainOnlyAnAssignmentGateAcrossRecords() {
        var state = Redactor.StreamState()
        #expect(Redactor.normalizingStructuredCredentialKeys(in: #"{"pass\u0077"#, state: &state) == #"{"secret""#)
        #expect(state.pendingEncodedCredentialKey)
        #expect(Redactor.normalizingStructuredCredentialKeys(in: "or", state: &state) == "[redacted:encoded-key]")
        #expect(state.pendingEncodedCredentialKey)
        #expect(Redactor.normalizingStructuredCredentialKeys(in: #"d":"syntheticOpaque"}"#, state: &state)
            == #""secret":"syntheticOpaque"}"#)
        #expect(!state.pendingEncodedCredentialKey)
        #expect(Redactor.normalizingStructuredCredentialKeys(in: "Finished", state: &state) == "Finished")
    }

    @Test(arguments: ["\r", "\n", "\r\n"])
    func physicalTerminatorsInsideEncodedKeysFailClosed(_ terminator: String) {
        let input = #"{"pass\u0077"# + terminator + #"word":"syntheticOpaque"}"#
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == #"{"secret":"syntheticOpaque"}"#)
    }

    @Test(arguments: [
        (#""pass\u0077ord":"syntheticOpaque""#, #""password":"syntheticOpaque""#),
        (#"\"pass\u0077ord\":\"syntheticOpaque\""#, #"\"password\":\"syntheticOpaque\""#),
        (#"{"pass\u0077ord"="syntheticOpaque"}"#, #"{"password"="syntheticOpaque"}"#)
    ])
    func encodedKeyFramingSharesTheDownstreamFieldDelimiters(_ input: String, _ expected: String) {
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == expected)
    }

    @Test(arguments: [1, 2, 16, 256])
    func escapedKeyFramesPreserveTheirOriginalDepth(_ depth: Int) {
        let quote = String(repeating: "\\", count: depth) + "\""
        let input = quote + #"pass\u0077ord"# + quote + ":" + quote + "syntheticOpaque" + quote
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input)
            == quote + "password" + quote + ":" + quote + "syntheticOpaque" + quote)
    }

    @Test(arguments: [
        (#"{"pass\u0077ord""#, #"{"password""#),
        ("{\r\n  " + #""pass\u0077ord": "syntheticOpaque""# + "\r\n}", "{\r\n  " + #""password": "syntheticOpaque""# + "\r\n}"),
        ("{\n  " + #""pass\u0077ord": "syntheticOpaque""# + "\n}", "{\n  " + #""password": "syntheticOpaque""# + "\n}"),
        (#"{"pass\u0077ord""# + "\r\n:" + #""syntheticOpaque"}"#, #"{"password""# + "\r\n:" + #""syntheticOpaque"}"#),
        (#"{"pass\u0077ord":"syntheticOpaque"}"#, #"{"password":"syntheticOpaque"}"#),
        (#"{"\u0061ccess_token":"syntheticOpaque"}"#, #"{"access_token":"syntheticOpaque"}"#),
        (#"{"device_\u0063ode":"abcd"}"#, #"{"device_code":"abcd"}"#),
        (#"{"\u0041uthorization":"syntheticOpaque"}"#, #"{"Authorization":"syntheticOpaque"}"#),
        (#"{"outer":{"pass\u0077ord":"one","user_\u0063ode":"two"}}"#, #"{"outer":{"password":"one","user_code":"two"}}"#),
        (#"  "pass\u0077ord" : "syntheticOpaque""#, #"  "password" : "syntheticOpaque""#)
    ])
    func encodedCredentialKeysUseTheExistingFieldGrammar(_ input: String, _ expected: String) {
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == expected)
    }

    @Test(arguments: [
        #"{"na\u006de":"visible","value":"pass\u0077ord"}"#,
        #"password: \"synthetic\", status: ready"#,
        #"Authorization: \"synthetic\", status: ready"#,
        #"{"message":"{\"pass\\u0077ord\":\"visible\"}"}"#,
        #"{"message":"literal \"pass\\u0077ord\": visible"}"#,
        #"{"password":"already literal"}"#,
        #"{"password\u004cength":12}"#,
        #"{"pass\u0077ordSuffix":"visible"}"#
    ])
    func unknownKeysAndQuotedValuesAreNotReinterpreted(_ input: String) {
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == input)
    }

    @Test(arguments: [#"{'na\u006de':'visible'}"#, #"{'message':'INFO "pass\\u0077ord":"visible"'}"#,
                      #"{"message":"INFO 'pass\\u0077ord':'visible'"}"#])
    func singleQuotedKeysAndNestedValueFramesRemainDistinct(_ input: String) {
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == input)
    }

    @Test(arguments: [#"[\"--password\", \"opaqueCredential\"]"#, #"[\'--password\', \'opaqueCredential\']"#,
                      #"["--password", \"#, #"["--password", opaque\"#,
                      #"["--password", "first" \"#, #""\"{\\\"password\\\":\"""#])
    func serializedArgumentsAndEncodedValuesAreNotFieldKeys(_ input: String) {
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == input)
    }

    @Test(arguments: [
        (#"{"pass\u0077ord: syntheticOpaque}"#, #"{"secret": syntheticOpaque}"#),
        (#"{"pass\u0077ord"#, #"{"secret""#),
        (#"{"pass\u0077ord\":"syntheticOpaque"}"#, #"{"secret":"syntheticOpaque"}"#),
        (#"{"password\u0020":"syntheticOpaque"}"#, #"{"secret":"syntheticOpaque"}"#),
        (#"{"\u0020password":"syntheticOpaque"}"#, #"{"secret":"syntheticOpaque"}"#),
        (#"{"pass\uXXXXord":"syntheticOpaque"}"#, #"{"secret":"syntheticOpaque"}"#),
        (#"{"password\n":"syntheticOpaque"}"#, #"{"secret":"syntheticOpaque"}"#),
        (#"{"pass\uD800word":"syntheticOpaque"}"#, #"{"secret":"syntheticOpaque"}"#)
    ])
    func invalidEncodedKeysCannotInjectOutputFraming(_ input: String, _ expected: String) {
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == expected)
    }

    @Test func oversizedEncodedKeysDoNotReachTheJSONDecoder() {
        let key = String(repeating: "x", count: 1024) + #"\u0077"#
        let input = "{\"" + key + "\":\"syntheticOpaque\"}"
        #expect(Redactor.normalizingStructuredCredentialKeys(in: input) == #"{"secret":"syntheticOpaque"}"#)
    }
}
