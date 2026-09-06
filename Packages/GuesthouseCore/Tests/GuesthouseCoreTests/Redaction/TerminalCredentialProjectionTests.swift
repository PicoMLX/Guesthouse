import Testing
@testable import GuesthouseCore

@Suite struct TerminalCredentialProjectionTests {
    @Test(arguments: ["\u{1B}[@", "\u{9B}@", "\u{1B}@"],
          ["The login code is ", "The login code was rejected; retry "])
    func restoredLeadingCodeBoundariesProtectValues(_ command: String, _ context: String) throws {
        let input = context + "filename" + command + "AB12-CD34."
        let joined = TerminalControlGrammar.normalize(input)
        let span = try #require(Redactor.recoveredCredentialRanges(in: input, joined: joined, priorPrefixes: [])
            .ranges.first(where: { $0.kind == "device-code" }))
        #expect(String(decoding: Array(joined.utf8)[span.range], as: UTF8.self) == "AB12-CD34")
    }

    @Test(arguments: ["\r", "\n", "\r\n"], ["\u{1B}[31", "\u{9B}31", "\u{1B}"])
    func oversizedPendingEvidenceIncludesFramedPEM(_ terminator: String, _ command: String) {
        var continuation: TerminalControlEvidence.Continuation?
        let input = "-----BEGIN " + String(repeating: "X", count: 70) + " PRIVATE" + command + terminator
        #expect(TerminalControlEvidence.prepare(input, continuation: &continuation).text == "[redacted:terminal-ambiguity]")
        #expect(continuation?.quarantined == true)
    }

    @Test(arguments: ["\r", "\n", "\r\n"], ["\u{1B}[31p", "\u{9B}31p", "\u{1B}p"])
    func recoveredWrappedPrefixesExcludeRecordFraming(_ terminator: String, _ command: String) {
        let input = "gh" + command + "_" + terminator
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains("ghp_"))
    }

    @Test(arguments: ["(--password syntheticOpaque", "(--token syntheticOpaque", "(--password"])
    func genericCommandFramingPreservesOptions(_ body: String) {
        let input = "\u{1B}" + body
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains(body))
    }

    @Test(arguments: ["a" + String(repeating: "1", count: 70) + "=/",
                      "Enter " + String(repeating: "login ", count: 12) + "code"],
          ["\u{1B}", "\u{1B}[31", "\u{9B}31"])
    func anyOversizedPendingOpenerFailsClosed(_ prefix: String, _ command: String) {
        var continuation: TerminalControlEvidence.Continuation?
        #expect(TerminalControlEvidence.prepare(prefix + command, continuation: &continuation).text
            == "[redacted:terminal-ambiguity]")
        #expect(continuation?.quarantined == true)
        #expect(TerminalControlEvidence.prepare("/user:syntheticOpaque@example.com", continuation: &continuation).text
            == "[redacted:terminal-ambiguity]")
    }

    @Test(arguments: [2_000, 4_000, 8_000])
    func denseSingleReadingControlsKeepExactProjection(_ count: Int) throws {
        let input = String(repeating: "a\u{0}", count: count) + "end"
        let start = ContinuousClock.now
        let readings = try #require(TerminalControlEvidence.projections(in: input))
        print("dense-controls \(count): \(ContinuousClock.now - start)")
        let reading = try #require(readings.first)
        #expect(readings.count == 1)
        #expect(reading.text == String(repeating: "a", count: count) + "end")
        #expect(reading.offsets == Array(0...(count + 3)))
        #expect(reading.boundaries.count == count + 1)
    }

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
    func oversizedOptionsUseTheSameFailClosedEvidenceBudget(_ length: Int) {
        var continuation: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare("--" + String(repeating: "x", count: length) + "pass\u{1B}[31",
                                            continuation: &continuation)
        #expect(continuation?.quarantined == true)
        #expect(continuation?.prefixes.isEmpty == true)
        #expect(continuation?.prefixes.allSatisfy { $0.unicodeScalars.count <= 64 } == true)
    }

    @Test(arguments: ["-----BEGIN " + String(repeating: "X", count: 70) + "-----",
                      String(repeating: "ordinary", count: 20)])
    func completedCommandsDoNotQuarantineLongOrdinaryOrPEMRecords(_ prefix: String) {
        var continuation: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare(prefix + "\u{1B}[31m", continuation: &continuation)
        #expect(continuation == nil)
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
