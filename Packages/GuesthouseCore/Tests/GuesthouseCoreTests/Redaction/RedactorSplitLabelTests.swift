import Testing
@testable import GuesthouseCore

@Suite struct RedactorSplitLabelTests {

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
    }
    @Test(arguments: ["\u{1B}[31/-m", "\u{9B}31/-m", "\u{1B}/-m"])
    func individualIntermediatesConcealThePhysicalAPIKey(_ command: String) {
        #expect(!Redactor().redact("sk" + command + "abcdefghijklmnopq").contains("abcdefghijklmnopq"))
    }

    @Test(arguments: [".", "-", "@"], ["The login code is ", "The login code was rejected; retry "])
    func punctuationBeforeAContextualCodeDoesNotExposeIt(_ punctuation: String, _ context: String) {
        #expect(!Redactor().redact(context + "filename" + punctuation + "\u{0}ABCD-EFGH").contains("ABCD-EFGH"))
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
        #expect(output.last == "status: done")
    }


    @Test(arguments: [
        [#"Digest username="Mufasa","#, #"realm="syntheticRealm","#, #"response="syntheticOpaque""#],
        ["AWS4-HMAC-SHA256 Credential=syntheticFirst,", "SignedHeaders=syntheticHeaders,", "Signature=syntheticOpaque"]
    ])
    func parameterizedAuthorizationOwnsEveryCommaContinuation(_ lines: [String]) {
        let output = Redactor().redact(lines: lines + ["status: ready"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[1] == "[redacted:authorization]" && output[2] == "[redacted:authorization]")
        #expect(output.last == "status: ready")
    }

    @Test(arguments: [
        ["--pass", "word syntheticOpaque"],
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
