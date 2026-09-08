import Testing
@testable import GuesthouseCore

@Suite struct RedactorSplitLabelTests {
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
