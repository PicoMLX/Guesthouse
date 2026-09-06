import Testing
@testable import GuesthouseCore

@Suite struct TerminalControlGrammarTests {
    @Test(arguments: ["\u{9C}", "\u{85}", "\u{80}", "é", "\u{301}"], ["\u{1B}(", "\u{1B}[31"])
    func anInterruptingScalarCannotExposeAReconstructedPrefix(interruption: String, opener: String) {
        var pending: TerminalControlGrammar.Pending?
        _ = TerminalControlGrammar.prepare(opener, pending: &pending)
        let expected = interruption.unicodeScalars.first!.value > 0x9F ? interruption + "after" : "after"
        #expect(TerminalControlGrammar.normalize(TerminalControlGrammar.prepare(interruption + "after", pending: &pending)) == expected)
        #expect(pending == nil)
    }

    @Test(arguments: ["\r", "\n", "\r\n"], [("\u{1B}[31", "m"), ("\u{9B}31", "m"), ("\u{1B}(", "B"), ("\u{1B}", "c")])
    func trailingPhysicalFramingDoesNotReleaseAnIncompleteCommand(framing: String, parts: (String, String)) {
        var pending: TerminalControlGrammar.Pending?
        #expect(TerminalControlGrammar.prepare("password: " + parts.0 + framing, pending: &pending) == "password: " + framing)
        #expect(pending != nil)
        #expect(TerminalControlGrammar.normalize(TerminalControlGrammar.prepare(parts.1 + "syntheticPassword" + framing, pending: &pending))
                == "syntheticPassword" + framing)
        #expect(pending == nil)
    }

    @Test func controlDenseRecordsRetainOnlyTheirUnfinishedSuffix() {
        var pending: TerminalControlGrammar.Pending?
        let controls = String(repeating: "\u{0}", count: 100_000)
        #expect(TerminalControlGrammar.prepare(controls + "\u{1B}[31", pending: &pending) == controls)
        #expect(pending == .csi)
    }

    @Test(arguments: ["\u{1B}[", "\u{9B}", "\u{1B}\u{0}["], ["31", " 31", "1 2", "31\u{0}", ""])
    func incompleteCSIIsNotAnOrdinaryFieldValue(start: String, body: String) {
        var pending: TerminalControlGrammar.Pending?
        #expect(TerminalControlGrammar.prepare("password: " + start + body, pending: &pending) == "password: ")
        #expect(pending == .csi)
        #expect(TerminalControlGrammar.normalize(TerminalControlGrammar.prepare("msyntheticPassword", pending: &pending)) == "syntheticPassword")
        #expect(pending == nil)
    }

    @Test(arguments: [("\u{1B}", "c"), ("\u{1B}(", "B"), ("\u{1B}\u{0}(", "B")])
    func incompleteGenericEscapesResumeWithoutExposingIntermediates(parts: (String, String)) {
        var pending: TerminalControlGrammar.Pending?
        #expect(TerminalControlGrammar.prepare("password: " + parts.0, pending: &pending) == "password: ")
        #expect(pending != nil)
        #expect(TerminalControlGrammar.normalize(TerminalControlGrammar.prepare(parts.1 + "syntheticPassword", pending: &pending)) == "syntheticPassword")
        #expect(pending == nil)
    }

    @Test(arguments: ["\u{18}", "\u{1A}", "\u{1B}[m"])
    func cancellationEndsAnIncompleteCSI(cancel: String) {
        var pending: TerminalControlGrammar.Pending?
        _ = TerminalControlGrammar.prepare("\u{1B}[31", pending: &pending)
        #expect(TerminalControlGrammar.normalize(TerminalControlGrammar.prepare(cancel + "after", pending: &pending)) == "after")
        #expect(pending == nil)
    }

    @Test func pendingStateDoesNotAccumulateParameters() {
        var pending: TerminalControlGrammar.Pending?
        _ = TerminalControlGrammar.prepare("\u{1B}[", pending: &pending)
        #expect(TerminalControlGrammar.prepare(String(repeating: "1", count: 10_000), pending: &pending).isEmpty)
        #expect(pending == .csi)
        #expect(TerminalControlGrammar.prepare("", pending: &pending).isEmpty)
        #expect(pending == .csi)
    }

    @Test(arguments: ["\u{1B}[0m", "\u{9B}0m", "\u{1B}(B"], ["\u{301}", "\u{FE0F}"])
    func combiningScalarsCannotChangeTheControlGrammar(control: String, suffix: String) {
        #expect(TerminalControlGrammar.normalize("red" + control + suffix + "text") == "red" + suffix + "text")
    }

    @Test(arguments: ["\u{1B}]", "\u{1B}\u{0}]", "\u{9D}"], ["\u{90}", "\u{98}", "\u{9E}", "\u{9F}"])
    func nestedPayloadIntroducersCannotArmPendingState(opener: String, nested: String) {
        var pending: TerminalControlGrammar.Pending?
        #expect(TerminalControlGrammar.normalize(TerminalControlGrammar.prepare(opener + "title" + nested + "payload\u{7}after", pending: &pending)) == "after")
        #expect(pending == nil)
        #expect(TerminalControlGrammar.prepare("Finished", pending: &pending) == "Finished")
    }

    @Test(arguments: [("\u{1B}]", "\u{7}"), ("\u{1B}P", "\u{1B}\\"), ("\u{1B}\u{0}_", "\u{9C}")])
    func controlStringStateKeepsItsOwnTerminator(parts: (String, String)) {
        var pending: TerminalControlGrammar.Pending?
        #expect(TerminalControlGrammar.prepare("before" + parts.0 + "payload", pending: &pending) == "before")
        #expect(pending != nil)
        #expect(TerminalControlGrammar.prepare("hidden", pending: &pending) == "")
        #expect(TerminalControlGrammar.normalize(TerminalControlGrammar.prepare(parts.1 + "after", pending: &pending)) == "after")
        #expect(pending == nil)
    }

    @Test func ordinaryPhysicalFramingIsPreserved() {
        #expect(TerminalControlGrammar.normalize("a\t\u{8}b\r\n") == "a\tb\r\n")
    }
    @Test(arguments: ["\u{1B}[", "\u{9B}"], ["\u{0}31", "3\u{0}1", "31\u{7}", "31\u{8}", "31\u{9}", "31 \u{0}", " 31", "1 2", "? 3"])
    func embeddedControlsDoNotSplitCSI(introducer: String, body: String) {
        let result = renderings(of: "pass" + introducer + body + "mword: syntheticPassword")
        #expect(result.joined == "password: syntheticPassword")
    }

    @Test(arguments: ["\u{18}", "\u{1A}"])
    func cancellationIsNotAnIgnoredCSIByte(cancel: String) {
        #expect(stripTerminalEscapes("pass\u{1B}[31" + cancel + "word: syntheticPassword") == "password: syntheticPassword")
    }

    @Test func aNewEscapeCancelsAnIncompleteCSI() {
        #expect(stripTerminalEscapes("pass\u{1B}[31\u{1B}[0mword: syntheticPassword") == "password: syntheticPassword")
    }

    @Test(arguments: ["\u{0}", "\u{7}", "\u{9}", "\u{7F}"], ["", "("])
    func embeddedGenericControlsStayInsideTheirCommand(control: String, intermediate: String) {
        #expect(renderings(of: "pass\u{1B}" + intermediate + control + "wword: syntheticPassword").joined
                == "password: syntheticPassword")
    }

    @Test(arguments: ["\u{1B}]", "\u{9D}"], ["\u{90}", "\u{98}", "\u{9E}", "\u{9F}"])
    func consumedOSCPayloadCannotArmAnotherControlString(opener: String, nested: String) {
        var open: TerminalControlGrammar.Pending?
        #expect(stripTerminalEscapes(opener + "title" + nested + "payload\u{7}after", openControlString: &open).joined == "after")
        #expect(open == nil)
        #expect(stripTerminalEscapes("Finished", openControlString: &open).joined == "Finished")
        _ = stripTerminalEscapes(opener + "title" + nested + "payload\u{7}\u{1B}Ppending", openControlString: &open)
        #expect(open == .other)
    }

    @Test(arguments: ["\u{1B}]", "\u{1B}P", "\u{1B}_", "\u{1B}^", "\u{1B}X", "\u{9D}", "\u{90}", "\u{9F}", "\u{9E}", "\u{98}"], ["\u{18}", "\u{1A}", "\u{1B}c", "\u{1B}[m"])
    func cancelledControlStringsReleaseVisibleDiagnostics(opener: String, cancel: String) {
        var open: TerminalControlGrammar.Pending?
        #expect(stripTerminalEscapes("before" + opener + "payload" + cancel + "after", openControlString: &open).joined == "beforeafter")
        #expect(open == nil)
        _ = stripTerminalEscapes(opener + "payload", openControlString: &open)
        #expect(stripTerminalEscapes(cancel + "after", openControlString: &open).joined == "after")
        #expect(open == nil)
        #expect(stripTerminalEscapes("Finished", openControlString: &open).joined == "Finished")
    }

    @Test(arguments: [("\u{1B}]", "\u{7}"), ("\u{1B}P", "\u{1B}\\")])
    func controlStringsRemainHiddenUntilTheirOwnTerminator(opener: String, terminator: String) {
        var open: TerminalControlGrammar.Pending?
        #expect(stripTerminalEscapes("before" + opener + "payload", openControlString: &open).joined == "before")
        #expect(open != nil)
        #expect(stripTerminalEscapes("hidden", openControlString: &open).joined == "")
        #expect(stripTerminalEscapes(terminator + "after", openControlString: &open).joined == "after")
        #expect(open == nil)
    }


    private struct Rendering { let joined: String }
    private func renderings(of text: String) -> Rendering {
        Rendering(joined: TerminalControlGrammar.normalize(text))
    }
    private func stripTerminalEscapes(_ text: String) -> String { TerminalControlGrammar.normalize(text) }
    private func stripTerminalEscapes(_ text: String, openControlString: inout TerminalControlGrammar.Pending?) -> Rendering {
        Rendering(joined: TerminalControlGrammar.normalize(TerminalControlGrammar.prepare(text, pending: &openControlString)))
    }
}
