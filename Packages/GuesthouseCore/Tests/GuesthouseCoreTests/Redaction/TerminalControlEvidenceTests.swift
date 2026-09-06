import Testing
@testable import GuesthouseCore

@Suite struct TerminalControlEvidenceTests {
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
        #expect(pending.prefixes == ["s", "s", "s", "s"])
        let next = TerminalControlEvidence.prepare("k-abcdefghijklmnop", continuation: &state)
        #expect(next.prefixes == ["s", "s", "s", "s"])
        #expect(!next.text.hasPrefix("s"))
        #expect(state == nil)
    }

    @Test func successiveCommandsKeepIndependentFixedReadings() throws {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare("s\u{1B}[31", continuation: &state)
        _ = TerminalControlEvidence.prepare("k\u{1B}[32", continuation: &state)
        #expect(try #require(state).prefixes == ["s", "sk", "sk", "sk"])
        _ = TerminalControlEvidence.prepare(String(repeating: "1", count: 10_000), continuation: &state)
        #expect(try #require(state).prefixes == ["s", "sk", "sk", "sk"])
    }

    @Test(arguments: ["a", "🧪", "\u{301}"])
    func lookbehindIsBoundedInScalarsAndBytes(_ scalar: String) throws {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare(String(repeating: scalar, count: 10_000) + "\u{1B}[", continuation: &state)
        let prefixes = try #require(state).prefixes
        #expect(prefixes.count == 4)
        #expect(prefixes.allSatisfy { $0.unicodeScalars.count <= 64 && $0.utf8.count <= 256 })
    }

    @Test func controlStringsDoNotCarryVisiblePrefixesThroughTheirPayload() throws {
        var state: TerminalControlEvidence.Continuation?
        _ = TerminalControlEvidence.prepare("s\u{1B}]payload", continuation: &state)
        #expect(try #require(state).prefixes == [])
        let next = TerminalControlEvidence.prepare("hidden\u{7}after", continuation: &state)
        #expect(next.text == "after")
        #expect(next.prefixes == [])
        #expect(state == nil)
    }
}
