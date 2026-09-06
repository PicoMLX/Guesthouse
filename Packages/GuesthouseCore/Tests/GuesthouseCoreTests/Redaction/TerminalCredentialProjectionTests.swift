import Testing
@testable import GuesthouseCore

@Suite struct TerminalCredentialProjectionTests {
    @Test(arguments: ["ghp_synthetic", "--password opaque", "remote=//user:opaque@host",
                      "Authorization: opaque", "device_code: opaque", "-----BEGIN PRIVATE KEY-----"])
    func independentCredentialOpenersRemainRecognizable(_ suffix: String) {
        #expect(Redactor.terminalHasCredentialOpener(suffix[...]))
    }

    @Test(arguments: ["filename", "build_status", "ordinary diagnostic"])
    func ordinarySuffixesAreNotCredentialOpeners(_ suffix: String) {
        #expect(!Redactor.terminalHasCredentialOpener(suffix[...]))
    }

    @Test(arguments: [60, 70, 256], ["\u{1B}[31", "\u{9B}31", "\u{1B}"])
    func longPendingPEMEvidenceIsQuarantined(_ length: Int, _ command: String) {
        var continuation: TerminalControlEvidence.Continuation?
        let result = TerminalControlEvidence.prepare(
            "-----BEGIN " + String(repeating: "X", count: length) + " PRIVATE" + command,
            continuation: &continuation)
        #expect(result.text == "[redacted:terminal-ambiguity]")
        #expect(continuation?.quarantined == true)
        #expect(continuation?.prefixes.isEmpty == true)
    }

    @Test(arguments: [60, 70, 256])
    func boundedLongOptionsRetainTheirStructuralDash(_ length: Int) {
        var continuation: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare("--" + String(repeating: "x", count: length) + "pass\u{1B}[31",
                                            continuation: &continuation)
        #expect(continuation?.prefixes.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("pass") }) == true)
        #expect(continuation?.prefixes.allSatisfy { $0.unicodeScalars.count <= 64 } == true)
    }

    @Test(arguments: ["-----BEGIN " + String(repeating: "X", count: 70) + "-----",
                      String(repeating: "ordinary", count: 20)])
    func CompletePEMAndOrdinaryTextDoNotTriggerTruncationQuarantine(_ prefix: String) {
        var continuation: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare(prefix + "\u{1B}[31", continuation: &continuation)
        #expect(continuation?.quarantined == false)
    }


    @Test(arguments: ["\u{1B}[@", "\u{9B}@", "\u{1B}@"],
          ["The login code is ", "The login code was rejected; retry "])
    func restoredTrailingBoundariesProtectContextualCodes(_ command: String, _ context: String) throws {
        let input = context + "AB12-CD34" + command + "filename"
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: [])
            .ranges.first(where: { $0.kind == "device-code" }))
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "AB12-CD34")
    }


    @Test(arguments: ["\u{1B}[31@", "\u{9B}31@", "\u{1B}@"],
          ["sk-abcdefghijklmnopq", "Bearer syntheticToken", "Basic dXNlcjpwYXNz"])
    func restoredLeadingBoundariesAreCredentialEvidence(_ escape: String, _ token: String) {
        let input = "filename" + escape + token
        let joined = TerminalControlGrammar.normalize(input)
        let ranges = Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: []).ranges
        #expect(ranges.contains(where: {
            String(decoding: Array(joined.utf8)[$0.range], as: UTF8.self) == token
        }))
    }

    @Test(arguments: ["\u{1B}", "\u{1B}[31", "\u{9B}31"])
    func restoredCodeContextProtectsAnUnmodifiedValue(_ escape: String) throws {
        let input = "The login co" + escape + "de was rejected; retry AB12-CD34."
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: [])
            .ranges.first(where: { $0.kind == "device-code" }))
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "AB12-CD34")
    }

    @Test(arguments: ["\u{1B}[31", "\u{9B}31"])
    func ordinaryCoverageRequiresAnActualCredentialBoundary(_ escape: String) throws {
        let input = "filename" + escape + "@sk-" + escape + "abcdefghijklmnopq done"
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: [])
            .ranges.first(where: { $0.kind == "api-key" }))
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "sk-bcdefghijklmnopq")
    }

    @Test(arguments: ["\u{1B}--pass\u{1B}[31word syntheticOpaque",
                      "\u{1B}--passw\u{1B}[31ord syntheticOpaque"])
    func mixedOptionsProduceScanOnlyContexts(_ input: String) {
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains("--password syntheticOpaque"))
    }

    @Test func deviceCodeOffsetsCoverOnlySurvivingValueBytes() throws {
        let input = "The login code was rejected; retry AB12-\u{1B}CD34."
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: []).ranges.first)
        #expect(span.kind == "device-code")
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "AB12-D34")
    }

    @Test func priorPrefixEvidenceProjectsOntoOnlyTheCurrentRecord() throws {
        let input = "\u{1B}[31k-abcdefghijklmnop"
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: ["s"]).ranges.first)
        #expect(span.kind == "api-key")
        #expect(span.range == 0..<joined.utf8.count)
    }

    @Test func opaquePayloadCannotBecomeCredentialEvidence() {
        let input = "before\u{1B}]password: syntheticOpaque\u{7}after"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: "beforeafter", priorPrefixes: [])
        #expect(result.ranges.isEmpty)
        #expect(result.contexts.isEmpty)
    }

    @Test func overBudgetAlternativesConcealTheCurrentVisibleRecord() {
        let input = String(repeating: "\u{1B}[31m", count: 8) + "opaque"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: "opaque", priorPrefixes: [])
        #expect(result.ranges.map(\.range) == [0..<6])
        #expect(result.ranges.map(\.kind) == ["terminal-ambiguity"])
    }
}
