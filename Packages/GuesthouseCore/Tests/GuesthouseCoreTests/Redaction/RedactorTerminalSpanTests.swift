import Testing
@testable import GuesthouseCore

@Suite struct RedactorTerminalSpanTests {
    @Test func contextualCodeEvidenceContainsOnlyTheCodeSpan() throws {
        let text = "The login code was rejected; retry AB12-CD34."
        let span = try #require(Redactor.terminalCredentialSpans(in: text).first { $0.kind == "device-code" })
        #expect(text[span.range] == "AB12-CD34")
        #expect(!span.needsBoundary)
        #expect(!Redactor.terminalCredentialSpans(in: "Build revision AB12-CD34.").contains { $0.kind == "device-code" })
    }

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
