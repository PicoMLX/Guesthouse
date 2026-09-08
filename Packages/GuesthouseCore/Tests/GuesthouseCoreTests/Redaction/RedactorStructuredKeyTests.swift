import Testing
@testable import GuesthouseCore

@Suite struct RedactorStructuredKeyTests {
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
        #"{"message":"{\"pass\\u0077ord\":\"visible\"}"}"#,
        #"{"message":"literal \"pass\\u0077ord\": visible"}"#,
        #"{"password":"already literal"}"#,
        #"{"password\u004cength":12}"#,
        #"{"pass\u0077ordSuffix":"visible"}"#
    ])
    func unknownKeysAndQuotedValuesAreNotReinterpreted(_ input: String) {
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
