import Testing
@testable import GuesthouseCore

/// Extended terminal regressions accompany the bounded implementation stack.
@Suite struct RedactorTerminalExtendedTests {
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
