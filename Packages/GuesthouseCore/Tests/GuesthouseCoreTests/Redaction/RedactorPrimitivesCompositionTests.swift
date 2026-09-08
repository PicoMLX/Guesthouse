import Testing
@testable import GuesthouseCore

@Suite struct RedactorPrimitivesCompositionTests {
    @Test(arguments: [["Enter the supp", "lied code syntheticOpaque"],
                      ["Your code sho", "wn below: syntheticOpaque"],
                      ["Your code sho", "wn be", "low: syntheticOpaque"],
                      ["Enter the", " code syntheticOpaque"],
                      ["Enter one two", "\tcode syntheticOpaque"],
                      ["Enter the supp", "lied co", "de syntheticOpaque"],
                      ["Your code i", "s syntheticOpaque"], ["device code rea", "ds syntheticOpaque"],
                      ["Your code re", "a", "ds syntheticOpaque"],
                      ["--ven", "dor-pass", "word syntheticOpaque"]])
    func restoredPromptAndOptionFragmentsConcealTheirWholeValue(_ records: [String]) {
        let output = Redactor().redact(lines: records + ["; Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic") && !output.joined().contains("Opaque"))
        #expect(output.joined().contains("[redacted:"))
        #expect(output.last == "; Finished")
    }

    @Test(arguments: ["abc 123", "abcd efgh", "abc DEF 123", "a bc d"])
    func lowercaseLedCodeGroupsAreConcealedTogether(_ value: String) {
        #expect(Redactor().redact("Enter the code " + value + ", then continue")
            == "Enter the code [redacted:device-code], then continue")
    }

    @Test(arguments: ["user code", "device code", "verification code", "Enter the code"])
    func singularStemCanContinueIntoAPluralCodeField(_ first: String) {
        let output = Redactor().redact(lines: [first, "s: syntheticOpaque", "; Finished"]).map(\.text)
        #expect(output[1].hasSuffix("[redacted:device-code]"))
        #expect(!output.joined().contains("synthetic") && !output.joined().contains("Opaque"))
        #expect(output[2] == "; Finished")
    }

    @Test(arguments: ["enter", "type", "paste", "copy", "input"]
        .flatMap { verb in (1...verb.count).map { (verb, $0) } })
    func everyVerbSplitConcealsTheFollowingCode(_ verb: String, _ split: Int) {
        let output = Redactor().redact(lines: [String(verb.prefix(split)),
            String(verb.dropFirst(split)) + " the code syntheticOpaque", "; Finished"]).map(\.text)
        #expect(output[1].hasSuffix("[redacted:device-code]"))
        #expect(!output.joined().contains("synthetic") && !output.joined().contains("Opaque"))
        #expect(output[2] == "; Finished")
    }

    @Test(arguments: [
        [#""htt"#, #"ps\u003a\u002f\u002fuser:syntheticOpaque\u0040example.com""#],
        [#""pass\u0077ord:"syntheticOpaque""#],
        [#"{'pass\u0077ord':'syntheticOpaque'}"#],
        [#"INFO "pass\u0077ord":"syntheticOpaque""#],
        [#"{"url":""#, #"\u002f\u002fuser:syntheticOpaque\u0040example.com"}"#],
        ["[//one.example;//user:syntheticOpaque@two.example]"],
        ["--url", "=//user:syntheticOpaque@example.com/path"],
        [#"{"url":"https"#, #"\u003a\u002f\u002fuser:syntheticOpaque\u0040example.com"}"#],
        [#""{\"url\":\"https:\\u002f\\u002fuser:syntheticOpaque\\u0040example.com\"}""#],
        [#"\"pass\u0077ord\":\"syntheticOpaque\""#],
        [#"{"pass\u0077ord"="syntheticOpaque"}"#]
    ])
    func encodedAndAssignedFramesConcealAllCredentialFragments(_ records: [String]) {
        let output = Redactor().redact(lines: records + ["; Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic") && !output.joined().contains("Opaque"))
        #expect(output.joined().contains("[redacted:"))
        #expect(output.last == "; Finished")
    }

    @Test(arguments: [#"{"url":"https:\u002f\u002fexample.com"}"#, #""https:\u002f\u002fexample.com:443""#,
                      "https://[::1]", "https://[2001:db8::1]:443"])
    func closedEncodedHostOnlyURLsPreserveDiagnostics(_ input: String) {
        #expect(Redactor().redact(lines: [input, "Finished"]).map(\.text) == [input, "Finished"])
    }

    @Test(arguments: ["\r", "\n", "\r\n"])
    func malformedEncodedKeyTerminatorsCannotExposeAValue(_ terminator: String) {
        let input = #"{"pass\u0077"# + terminator + #"word":"syntheticOpaque"}"#
        let output = Redactor().redact(untrusted: input)
        #expect(!output.contains("synthetic") && !output.contains("Opaque"))
        #expect(output.contains("[redacted:"))
    }

    @Test func encodedKeyFragmentsCannotReleaseTheLaterAssignment() {
        let output = Redactor().redact(lines: [#"{"pass\u0077"#, "or", #"d":"syntheticOpaque"}"#, "Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic") && !output.joined().contains("Opaque"))
        #expect(output[1] == "[redacted:encoded-key]")
        #expect(output.last == "Finished")
    }

    @Test(arguments: ["Cookie", "Set-Cookie"])
    func cookieFoldsConcealTheNextPhysicalRecord(_ header: String) {
        let output = Redactor().redact(lines: [header + ": session=syntheticFirst", " syntheticSecond", "Finished"]).map(\.text)
        #expect(output == [header + ": [redacted:authorization]", "[redacted:authorization]", "Finished"])
    }
}
