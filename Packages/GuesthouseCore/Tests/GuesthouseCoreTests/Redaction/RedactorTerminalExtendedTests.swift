import Testing
@testable import GuesthouseCore

/// Extended terminal regressions accompany the bounded implementation stack.
@Suite struct RedactorTerminalExtendedTests {
    @Test(arguments: ["\u{1B}[", "\u{9B}"])
    func intermediateOnlyCSIReadingsRecoverURLDelimiters(_ introducer: String) {
        let input = "https:" + introducer + "31/m/user:syntheticOpaque@host"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.ranges.contains { $0.kind == "userinfo" })
    }

    @Test(arguments: ["password: ", "Authorization: ", "device_code: ", "--password "])
    func restoredTrailingBackslashIsContinuationEvidence(_ field: String) {
        let input = field + "synthetic\u{1B}\\"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains(field + "synthetic\\"))
    }

    @Test(arguments: ["\u{1B}[:", "\u{9B}:", "\u{1B}/"], [64, 70])
    func overflowingPendingCommandBodiesQuarantineBeforeTruncation(_ command: String, _ length: Int) {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare("password" + command + String(repeating: command.hasSuffix("/") ? "/" : "1", count: length), continuation: &state)
        #expect(state?.quarantined == true)
        #expect(TerminalControlEvidence.prepare("msyntheticOpaque", continuation: &state).text == "[redacted:terminal-ambiguity]")
    }

    @Test(arguments: ["password: ", "Authorization: ", "device_code: ", "--password "],
          ["\"", "'", "\\\""])
    func restoredOpeningDelimitersAreStateEvidence(_ field: String, _ delimiter: String) {
        let input = field + "\u{1B}" + delimiter + "syntheticFirst"
        let result = Redactor.recoveredCredentialRanges(in: input, joined: TerminalControlGrammar.normalize(input), priorPrefixes: [])
        #expect(result.contexts.contains(field + delimiter + "syntheticFirst"))
    }

    @Test func largePlainRecordsAvoidTerminalProjectionBudgets() {
        let input = String(repeating: "ordinary", count: 10_000)
        var state: Redactor.StreamState.ControlString?
        let output = Redactor.stripTerminalEscapes(input, openControlString: &state)
        #expect(output.joined == input && output.spliced == input && state == nil)
    }

    @Test(arguments: [8_000, 100_000])
    func sparseRecordOverflowQuarantinesTheStream(_ count: Int) {
        var state: Redactor.StreamState.ControlString?
        let output = Redactor.stripTerminalEscapes("\u{1B}[31m\u{1B}[32m" + String(repeating: "a", count: count), openControlString: &state)
        #expect(output.spliced == "[redacted:terminal-ambiguity]" && state?.quarantined == true)
        #expect(Redactor.stripTerminalEscapes("syntheticNext", openControlString: &state).spliced == "[redacted:terminal-ambiguity]")
    }

    @Test func excessiveDistinctCSIComponentsQuarantineRatherThanTruncate() {
        let command = "\u{1B}[" + (1...65).map(String.init).joined(separator: ";") + "@"
        #expect(TerminalControlEvidence.projections(in: command)?.count == nil)
        var state: TerminalControlEvidence.Continuation?
        #expect(TerminalControlEvidence.prepare(command, continuation: &state).text == "[redacted:terminal-ambiguity]")
        #expect(state?.quarantined == true)
    }

    @Test(arguments: [8_000, 100_000])
    func sparseLongRecordsExceedTheRecoveryWorkBudget(_ length: Int) {
        let input = "\u{1B}[31m\u{1B}[32m" + String(repeating: "a", count: length)
        #expect(TerminalControlEvidence.projections(in: input)?.count == nil)
        var state: TerminalControlEvidence.Continuation?
        #expect(TerminalControlEvidence.prepare(input, continuation: &state).text == "[redacted:terminal-ambiguity]")
        #expect(state?.quarantined == true)
    }

    @Test func boundedSparseRecordsKeepEveryReading() throws {
        let readings = try #require(TerminalControlEvidence.projections(in: "\u{1B}[31m\u{1B}[32m" + String(repeating: "a", count: 1_000)))
        #expect(readings.count == 16)
        #expect(readings.allSatisfy { $0.offsets.count == $0.text.utf8.count + 1 })
    }

    @Test(arguments: [2_000, 4_000, 8_000])
    func formerlySlowDenseRecordsExceedTheExplicitControlBudget(_ count: Int) {
        #expect(TerminalControlEvidence.projections(in: String(repeating: "a\u{0}", count: count))?.count == nil)
    }

    @Test(arguments: [32, 128, 256])
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

    @Test(arguments: ["-----BEGIN " + String(repeating: "X", count: 70) + "-----",
                      String(repeating: "ordinary", count: 20)])
    func completedCommandsDoNotQuarantineLongOrdinaryOrPEMRecords(_ prefix: String) {
        var continuation: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare(prefix + "\u{1B}[31m", continuation: &continuation)
        #expect(continuation == nil)
    }

    @Test(arguments: [60, 70, 256], ["\u{1B}[31", "\u{9B}31", "\u{1B}"])
    func longPendingPEMOpenersFailClosedWithoutUnboundedEvidence(_ length: Int, _ command: String) {
        var open: Redactor.StreamState.ControlString?
        _ = Redactor.stripTerminalEscapes("-----BEGIN " + String(repeating: "X", count: length) + " PRIVATE" + command,
                                         openControlString: &open)
        let second = Redactor.stripTerminalEscapes("m KEY-----syntheticBody", openControlString: &open)
        #expect(!second.joined.contains("syntheticBody"))
        #expect(open?.quarantined == true)
        #expect(Redactor.stripTerminalEscapes("syntheticNext", openControlString: &open).joined
            == "[redacted:terminal-ambiguity]")
    }

    @Test(arguments: [60, 64, 256], ["\u{1B}[31", "\u{9B}31", "\u{1B}"])
    func longPendingOptionsQuarantineRatherThanTruncateTheirOpener(_ length: Int, _ command: String) {
        var open: Redactor.StreamState.ControlString?
        _ = Redactor.stripTerminalEscapes("--" + String(repeating: "x", count: length) + "pass" + command,
                                         openControlString: &open)
        let second = Redactor.stripTerminalEscapes("word syntheticOpaque", openControlString: &open)
        #expect(second.joined == "[redacted:terminal-ambiguity]")
        #expect(open?.quarantined == true)
    }

    @Test(arguments: [("\u{1B}]", "\u{7}"), ("\u{1B}P", "\u{1B}\\"),
                      ("\u{1B}_", "\u{9C}"), ("\u{1B}^", "\u{9C}"), ("\u{1B}X", "\u{9C}")],
          ["\r", "\n", "\r\n"])
    func wholeTextNormalizationPreservesOpaqueRecordFraming(parts: (String, String), separator: String) {
        #expect(Redactor.stripTerminalEscapes("before" + parts.0 + "title" + separator + "payload" + parts.1 + "after")
            == "before" + separator + "after")
    }

}
