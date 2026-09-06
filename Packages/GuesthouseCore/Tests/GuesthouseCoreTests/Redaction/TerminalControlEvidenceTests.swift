import Testing
@testable import GuesthouseCore

@Suite struct TerminalControlEvidenceTests {

    @Test(arguments: [("\u{1B}]", "\u{7}"), ("\u{1B}P", "\u{1B}\\"),
                      ("\u{1B}_", "\u{9C}"), ("\u{1B}^", "\u{9C}"), ("\u{1B}X", "\u{9C}")])
    func visiblePrefixesSurviveOpaquePayloads(parts: (String, String)) throws {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare("s" + parts.0 + "opaque", continuation: &state)
        #expect(try #require(state).prefixes == ["s"])
        #expect(TerminalControlEvidence.prepare("hidden", continuation: &state).text == "")
        let next = TerminalControlEvidence.prepare("hidden" + parts.1 + "k-proj-synthetic", continuation: &state)
        #expect(next.prefixes.contains("s"))
        #expect(next.text == "k-proj-synthetic")
        #expect(state == nil)
    }

    @Test(arguments: [("\u{1B}--", "password syntheticOpaque", "--p"),
                      ("\u{1B}[31", "word:", "31w"), ("\u{9B}31", "word:", "31w")])
    func completeCommandBodiesSurvivePhysicalBoundaries(parts: (String, String, String)) throws {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare(parts.0, continuation: &state)
        let next = TerminalControlEvidence.prepare(parts.1, continuation: &state)
        let escape = try #require(next.text.firstMatch(of: TerminalControlGrammar.escape))
        #expect(TerminalControlEvidence.body(of: escape.0, reading: .complete) == parts.2)
        #expect(state == nil)
    }
    @Test(arguments: [
        ("\u{1B}--p", "--p"), ("\u{1B}\u{0}--p", "--p"),
        ("\u{1B}[31k", "31k"), ("\u{9B}31k", "31k"),
    ])
    func completeReadingKeepsIntermediatesAndFinal(input: String, expected: String) {
        #expect(TerminalControlEvidence.body(of: input[...], reading: .complete) == expected)
        #expect(TerminalControlEvidence.body(of: input[...], reading: .joined) == "")
    }

    @Test(arguments: [("\u{1B}[31k", "k"), ("\u{1B}--p", "p"), ("\u{1B}(B", "B")])
    func finalReadingDoesNotRetainParameters(input: String, expected: String) {
        #expect(TerminalControlEvidence.body(of: input[...], reading: .final) == expected)
        #expect(TerminalControlEvidence.body(of: input[...], reading: .parameterless) == "")
    }

    @Test(arguments: ["\u{1B}]payload\u{7}", "\u{1B}Ppayload\u{1B}\\",
                      "\u{1B}_payload\u{9C}", "\u{1B}[31\u{18}", "\u{1B}[31"])
    func payloadAndAbortedCommandsAreNeverEvidence(_ input: String) {
        #expect(TerminalControlEvidence.body(of: input[...], reading: .complete) == "")
        #expect(TerminalControlEvidence.body(of: input[...], reading: .final) == "")
    }

    @Test(arguments: ["\u{1B}[31", "\u{9B}31", "\u{1B}", "\u{1B}("], ["", "\r", "\n", "\r\n"])
    func prefixesCrossACommandButNeverBecomeVisible(command: String, framing: String) throws {
        var state: TerminalControlEvidence.Continuation?
        let first = TerminalControlEvidence.prepare("s" + command + framing, continuation: &state)
        #expect(first.text == "s" + framing)
        #expect(first.prefixes == [])
        let pending = try #require(state)
        #expect(pending.prefixes == ["s"])
        let next = TerminalControlEvidence.prepare("k-abcdefghijklmnop", continuation: &state)
        #expect(next.prefixes == ["s"])
        #expect(!next.text.hasPrefix("s"))
        #expect(state == nil)
    }

    @Test func successiveCommandsKeepIndependentMixedReadings() throws {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare("s\u{1B}[31", continuation: &state)
        _ = TerminalControlEvidence.prepare("k\u{1B}[32", continuation: &state)
        #expect(Set(try #require(state).prefixes) == ["s", "sk", "s31k"])
        _ = TerminalControlEvidence.prepare(String(repeating: "1", count: 10_000), continuation: &state)
        #expect(Set(try #require(state).prefixes) == ["s", "sk", "s31k"])
        #expect(try #require(state).commandSuffix == String(repeating: "1", count: 64))
    }

    @Test(arguments: ["a", "🧪", "\u{301}"])
    func lookbehindIsBoundedInScalarsAndBytes(_ scalar: String) throws {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare(String(repeating: scalar, count: 10_000) + "\u{1B}[", continuation: &state)
        let prefixes = try #require(state).prefixes
        #expect(state?.quarantined == true)
        #expect(prefixes.isEmpty)
        #expect(prefixes.allSatisfy { $0.unicodeScalars.count <= 64 && $0.utf8.count <= 256 })
    }

    @Test(arguments: ["a", "🧪", "\u{301}"], [1, 64])
    func evidenceWithinTheScalarBudgetRemainsExact(_ scalar: String, _ count: Int) throws {
        var state: TerminalControlEvidence.Continuation?
        let prefix = String(repeating: scalar, count: count)
        _ = TerminalControlEvidence.prepare(prefix + "\u{1B}[", continuation: &state)
        #expect(try #require(state).prefixes == [prefix])
        #expect(state?.quarantined == false)
    }

    @Test func controlStringsCarryOnlyVisiblePrefixesNeverTheirPayload() throws {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare("s\u{1B}]payload", continuation: &state)
        #expect(try #require(state).prefixes == ["s"])
        let next = TerminalControlEvidence.prepare("hidden\u{7}after", continuation: &state)
        #expect(next.text == "after")
        #expect(next.prefixes == ["s"])
        #expect(state == nil)
    }

    @Test(arguments: ["\u{1B}--pass\u{1B}[31word syntheticOpaque",
                      "\u{1B}--passw\u{1B}[31ord syntheticOpaque"])
    func commandsChooseDifferentReadingsWithoutLosingProjection(_ input: String) throws {
        let readings = try #require(TerminalControlEvidence.projections(in: input))
        let mixed = try #require(readings.first { $0.text == "--password syntheticOpaque" })
        #expect(mixed.offsets.count == mixed.text.utf8.count + 1)
        #expect(mixed.offsets.last == TerminalControlGrammar.normalize(input).utf8.count)
        #expect(mixed.retained.count == 2)
    }

    @Test func opaqueCommandsDoNotMultiplyEquivalentReadings() throws {
        let input = String(repeating: "\u{1B}]hidden\u{7}", count: 100) + "visible"
        let readings = try #require(TerminalControlEvidence.projections(in: input))
        #expect(readings.count == 1)
        #expect(readings[0].text == "visible")
        #expect(readings[0].retained.isEmpty)
    }

    @Test func intermediateEvidenceKeepsPunctuationButNotCSIParameters() {
        #expect(TerminalControlEvidence.body(of: "\u{1B}[32-a"[...], reading: .intermediates) == "-a")
    }

    @Test func ambiguityOverflowQuarantinesSubsequentRecords() throws {
        let input = String(repeating: "\u{1B}[31m", count: 8) + "password:"
        #expect(TerminalControlEvidence.projections(in: input) == nil)
        var state: TerminalControlEvidence.Continuation?
        #expect(TerminalControlEvidence.prepare(input, continuation: &state).text == "[redacted:terminal-ambiguity]")
        #expect(try #require(state).quarantined)
        #expect(TerminalControlEvidence.prepare("syntheticOpaque", continuation: &state).text == "[redacted:terminal-ambiguity]")
        #expect(try #require(state).prefixes.isEmpty)
        #expect(try #require(state).commandSuffix.isEmpty)
        state = nil
        #expect(TerminalControlEvidence.prepare("Finished", continuation: &state).text == "Finished")
        #expect(state == nil)
    }
}
