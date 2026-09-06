import Testing
@testable import GuesthouseCore

@Suite struct TerminalCredentialProjectionTests {
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
