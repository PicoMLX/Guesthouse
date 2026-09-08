import Testing
@testable import GuesthouseCore

@Suite struct RedactorSplitLabelTests {

    @Test(arguments: [("gh", "p_syntheticOpaque"), ("gith", "ub_pat_syntheticOpaque")])
    func shortProviderStemsRetainWrappingUntilALexicalBoundary(_ first: String, _ second: String) {
        let output = Redactor().redact(lines: [first, second, "syntheticTail", ";", "status: ready"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output.last == "status: ready")
    }

    @Test(arguments: ["\u{1B}[:;//m", "\u{9B}:;//m"])
    func mixedTerminalClassesHideURLPasswords(_ command: String) {
        #expect(!Redactor().redact("https" + command + "user:syntheticOpaque@host").contains("syntheticOpaque"))
    }

    @Test(arguments: [#"args=["run '--password syntheticOpaque' --verbose"]"#,
                      #"args=['run "--password syntheticOpaque" --verbose']"#])
    func nestedCommandContainersReleasePublicOutput(_ input: String) {
        let output = Redactor().redact(lines: [input, "Finished"]).map(\.text)
        #expect(!output[0].contains("syntheticOpaque") && output[0].contains("--verbose"))
        #expect(output[1] == "Finished")
    }

    @Test(arguments: ["Basic", "Bearer", "NTLM", "Negotiate", "Digest", "AWS4-HMAC-SHA256"])
    func schemeOnlyHeadersConcealUnindentedOpaqueValues(_ scheme: String) {
        let output = Redactor().redact(lines: ["Authorization: " + scheme, "syntheticOpaque", "status: done"]).map(\.text)
        #expect(output[1] == "[redacted:authorization]" && output[2] == "status: done")
    }

    @Test(arguments: [("[AB", "C123]"), ("(AB", "C123)"), ("<AB", "C123>"), ("`AB", "C123`")])
    func framedCodeFragmentsRemainPrivateUntilClosed(_ first: String, _ second: String) {
        let output = Redactor().redact(lines: ["Enter the code " + first, second, "status: done"]).map(\.text)
        #expect(!output[0].contains("AB") && !output[1].contains("C123"))
        #expect(output[2] == "status: done")
    }

    @Test func anUnfinishedDeviceCodeNeedsNoIndentation() {
        let output = Redactor().redact(lines: ["Your code is ABCD-", "EFGH", "status: done"]).map(\.text)
        #expect(!output[0].contains("ABCD") && !output[1].contains("EFGH"))
        #expect(output[2] == "status: done")
    }

    @Test(arguments: ["\u{1B}[12345672m", "\u{9B}12345672m"])
    func parameterSuffixesConcealEveryVisibleCodeFragment(_ command: String) {
        let output = Redactor().redact("The login code was rejected; retry AB1" + command + "-CD34.")
        #expect(!output.contains("AB1") && !output.contains("CD34"))
    }

    @Test func pendingTerminalPrefixesDoNotEmitAUsableDeviceCode() {
        let output = Redactor().redact(lines: ["AB12-CD34 is your co\u{1B}[31", "mde", "Finished"]).map(\.text)
        #expect(!output.joined().contains("AB12-CD34"))
        #expect(!output.joined().contains("AB12") && !output.joined().contains("CD34"))
        #expect(output[2] == "Finished")
    }

    @Test func anEscapedDiagnosticApostropheCannotEndTheSecretEarly() {
        let output = Redactor().redact(lines: [#"['--password synthetic\'secretTail']"#, "Finished"]).map(\.text)
        #expect(!output[0].contains("synthetic") && !output[0].contains("secretTail"))
        #expect(output[1] == "Finished")
    }

    @Test(arguments: ["args=[", "args=[\"first\", "], ["\"", "'"])
    func enclosingContainerCommandsReleaseAfterTheirQuote(_ prefix: String, _ quote: String) {
        let lines = [prefix + quote + "run --password syntheticFirst", "syntheticSecond" + quote + "]", "Finished"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["\u{1B}[", "\u{9B}"])
    func ambiguousNumericComponentsQuarantineThePhysicalStream(_ introducer: String) {
        let lines = ["The login code was rejected; retry " + introducer + "912345678-ABCDEFGH", "syntheticNext"]
        #expect(Redactor().redact(lines: lines).map(\.text)
            == ["[redacted:terminal-ambiguity]", "[redacted:terminal-ambiguity]"])
    }

    @Test func aRecoveredTokenCannotEraseContextForAnAdjacentCode() {
        let input = "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.-code ABCD-EFGH"
        let output = Redactor().redact(input)
        #expect(!output.contains("payload"))
        #expect(!output.contains("ABCD-EFGH"))
        #expect(!output.contains("eyJhbGciOiJIUzI1NiIsI") && !output.contains("mtpZCI6Im5hYmMifQ"))
        #expect(!output.contains("ABCD") && !output.contains("EFGH"))
    }
    @Test(arguments: ["\u{1B}[31/-m", "\u{9B}31/-m", "\u{1B}/-m"])
    func individualIntermediatesConcealThePhysicalAPIKey(_ command: String) {
        #expect(!Redactor().redact("sk" + command + "abcdefghijklmnopq").contains("abcdefghijklmnopq"))
    }

    @Test(arguments: [".", "-", "@"], ["The login code is ", "The login code was rejected; retry "])
    func punctuationBeforeAContextualCodeDoesNotExposeIt(_ punctuation: String, _ context: String) {
        #expect(!Redactor().redact(context + "filename" + punctuation + "\u{0}ABCD-EFGH").contains("ABCD-EFGH"))
        let output = Redactor().redact(context + "filename" + punctuation + "\u{0}ABCD-EFGH")
        #expect(!output.contains("ABCD") && !output.contains("EFGH"))
        #expect(Redactor().redact("Build revision filename" + punctuation + "\u{0}ABCD-EFGH")
            == "Build revision filename" + punctuation + "ABCD-EFGH")
    }

    @Test(arguments: ["'", "\""])
    func completedOuterCommandQuotesReleaseFollowingDiagnostics(_ quote: String) {
        let output = Redactor().redact(lines: [quote + "--password syntheticOpaque" + quote, "Finished"]).map(\.text)
        #expect(!output[0].contains("syntheticOpaque"))
        #expect(output[1] == "Finished")
    }

    @Test(arguments: ["'", "\""])
    func unfinishedOuterCommandQuotesRetainTheWrappedValue(_ quote: String) {
        let output = Redactor().redact(lines: [quote + "--password syntheticFirst", "syntheticSecond" + quote, "Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["\u{1B}[2:3@", "\u{9B}2;3@", "\u{1B}[?2:3@", "\u{9B}2:3/m"])
    func CSIComponentsProtectTheVisibleCodeFragments(_ command: String) {
        let output = Redactor().redact("The login code was rejected; retry AB1" + command + "-CD34.")
        #expect(!output.contains("AB1"))
        #expect(!output.contains("CD34"))
        #expect(output.contains("[redacted:device-code]"))
    }

    @Test(arguments: ["@", ".", ")", "💻"], ["\u{0}", "\u{1B}[31m"])
    func independentOptionAfterOrdinaryPunctuationIsConcealed(_ punctuation: String, _ control: String) {
        let output = Redactor().redact("contact" + punctuation + control + "--password syntheticOpaque")
        #expect(!output.contains("syntheticOpaque"))
        #expect(output.contains("[redacted:secret]"))
    }

    @Test(arguments: [
        ["--pas", "", "\u{1B}[31m", "sw", "ord syntheticOpaque"],
        [#"["--pass"#, #"word", "syntheticOpaque"]"#],
        ["Authorization: Digest username=syntheticFirst,", "response=syntheticOpaque"],
        ["Set-Coo", "", "\u{1B}[0m", "kie:", "session=syntheticOpaque"],
        ["Enter the code \"", "syntheticOpaque\"", "status: ready"]
    ])
    func splitContextsSurviveFramingAndEmptyPhysicalRecords(_ lines: [String]) {
        let output = Redactor().redact(lines: lines + ["status: done"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(!output.joined().contains("syntheticFirst"))
        #expect(output.last == "status: done")
    }


    @Test(arguments: [
        [#"Digest username="Mufasa","#, #"realm="syntheticRealm","#, #"response="syntheticOpaque""#],
        ["AWS4-HMAC-SHA256 Credential=syntheticFirst,", "SignedHeaders=syntheticHeaders,", "Signature=syntheticOpaque"]
    ])
    func parameterizedAuthorizationOwnsEveryCommaContinuation(_ lines: [String]) {
        let output = Redactor().redact(lines: lines + ["status: ready"]).map(\.text)
        #expect(!output.joined().contains("synthetic") && !output.joined().contains("Mufasa"))
        #expect(output[1] == "[redacted:authorization]" && output[2] == "[redacted:authorization]")
        #expect(output.last == "status: ready")
    }

    @Test(arguments: [
        ["--pass", "word syntheticOpaque"],
        ["Authoriz", "ation: syntheticOpaque"], ["pass", "word: syntheticOpaque"],
        ["--github-", "token syntheticOpaque"], ["Bea", "rer syntheticOpaque"],
        ["password", ": syntheticOpaque"], ["Authorization", ": syntheticOpaque"],
        ["device_code", ": syntheticOpaque"],
        ["--pa", "ss", "word", "syntheticOpaque"],
        ["run --github-to", "ken syntheticOpaque"],
        ["--api-", "key=syntheticOpaque"],
        ["--device-co", "de syntheticOpaque"],
        ["Set-Coo", "kie: session=syntheticOpaque; HttpOnly"],
        ["Co", "ok", "ie:", "session=syntheticOpaque"],
        ["set-coo", "kie: session=syntheticOpaque"]
    ])
    func splitCredentialLabelsProtectTheirPhysicalValue(_ lines: [String]) {
        let output = Redactor().redact(lines: lines + ["status: ready"]).map(\.text)
        #expect(!output.joined().contains("syntheticOpaque"))
        #expect(output.last == "status: ready")
    }

    @Test(arguments: [["--format", "Finished"], ["Set-C", "ompiler ready"], ["Co", "mpilation succeeded"]])
    func unmatchedPartialLabelsDoNotRewriteTheFollowingDiagnostic(_ lines: [String]) {
        #expect(Redactor().redact(lines: lines).map(\.text) == lines)
    }
}
