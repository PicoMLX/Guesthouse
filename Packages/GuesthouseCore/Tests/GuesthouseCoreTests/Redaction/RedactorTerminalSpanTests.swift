import Testing
@testable import GuesthouseCore

@Suite struct RedactorTerminalSpanTests {
    @Test(arguments: ["sk-abcdefghijklmnop", "Bearer syntheticCredential"])
    func tokenSpansKeepTheirBoundaryRequirement(_ token: String) throws {
        let text = "filename" + token
        let span = try #require(Redactor.terminalCredentialSpans(in: text).first)
        #expect(text[span.range] == token)
        #expect(span.needsBoundary)
    }

    @Test func distinctiveGitHubSpansDoNotRequireAnExternalBoundary() throws {
        let text = "filenameghp_syntheticCredential"
        let span = try #require(Redactor.terminalCredentialSpans(in: text).first)
        #expect(text[span.range] == "ghp_syntheticCredential")
        #expect(!span.needsBoundary)
    }

    @Test func recoveredRangesExpandThroughOverlappingOrdinaryProtection() {
        let result = Redactor.expandingRecoveredRanges([(2..<4, "secret")], through: [0..<3, 3..<8])
        #expect(result.map(\.range) == [0..<8])
        #expect(result.map(\.kind) == ["secret"])
    }

    @Test func adjacentOrdinaryRangesDoNotInventExtraRecoveredProtection() {
        let result = Redactor.expandingRecoveredRanges([(0..<2, "secret")], through: [2..<8])
        #expect(result.map(\.range) == [0..<2])
        #expect(result.map(\.kind) == ["secret"])
    }
}
