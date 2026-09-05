import Foundation
import Testing
@testable import GuesthouseCore

/// Synthetic credentials only; every streaming case owns its state.
@Suite struct RedactorParsingTests {
    @Test(arguments: [("Zg", [UInt8(102)]), ("_w", [UInt8(255)]), ("-w", [UInt8(251)])])
    func base64URLAcceptsUnpaddedAndURLSafeSegments(input: String, bytes: [UInt8]) {
        #expect(Redactor.decodedBase64URL(input[...]) == Data(bytes))
    }

    @Test(arguments: ["a", "a*b-"])
    func malformedBase64URLIsRejected(input: String) {
        #expect(Redactor.decodedBase64URL(input[...]) == nil)
    }

    @Test(arguments: [(#"{"alg":"HS256"}"#, 3), (#" {"enc":"A256GCM"} "#, 5)])
    func joseHeadersDistinguishSignedAndEncryptedTokens(header: String, count: Int) {
        let encoded = Data(header.utf8).base64EncodedString()
        #expect(Redactor.joseSegmentCount(encoded[...]) == count)
        #expect(Redactor.joseSegmentCount("WzFd"[...]) == nil)
    }

    @Test(arguments: [
        ("artifacteyJhbGciOiJIUzI1NiJ9.cGF5bG9hZA.c2ln.tmp", "artifact[redacted:jwt].tmp"),
        ("eyJlbmMiOiJBMjU2R0NNIn0.key.iv.cipher.tag.tmp", "[redacted:jwt].tmp"),
        ("eyJlbmMiOiJBMjU2R0NNIn0.key.iv", "[redacted:jwt]"),
        ("release.version.123", "release.version.123"),
    ])
    func joseReplacementPreservesSurroundingNames(input: String, expected: String) {
        #expect(Redactor.redactedJWT(input[...]) == expected)
    }

    @Test(arguments: [("\u{1B}]", "\u{7}"), ("\u{1B}P", "\u{1B}\\")])
    func controlStringsRemainHiddenUntilTheirOwnTerminator(opener: String, terminator: String) {
        var open: Redactor.StreamState.ControlString?
        #expect(Redactor.stripTerminalEscapes("before" + opener + "payload", openControlString: &open).joined == "before")
        #expect(open != nil)
        #expect(Redactor.stripTerminalEscapes("hidden", openControlString: &open).joined == "")
        #expect(Redactor.stripTerminalEscapes(terminator + "after", openControlString: &open).joined == "after")
        #expect(open == nil)
    }

    @Test func terminalRenderingRetainsTokenBoundariesWithoutSplittingTokens() {
        let boundary = Redactor.renderings(of: "prefix\u{1B}[31mghp_demo")
        #expect(boundary.joined == "prefixghp_demo")
        #expect(boundary.spliced == "prefix" + Redactor.splicedBoundary + "ghp_demo")
        let interior = Redactor.renderings(of: "ghp_de\u{1B}[31mmo")
        #expect(interior.joined == "ghp_demo")
        #expect(interior.spliced == interior.joined)
        #expect(Redactor.stripTerminalEscapes("a\t\u{8}b\r\n") == "a\tb\r\n")
    }

    @Test(arguments: [#"first\ second --verbose"#, #"first" two"third --verbose"#, #"\"first second\" --verbose"#])
    func shellArgumentsIncludeEscapedWhitespaceAndAdjacentQuotes(input: String) {
        let argument = Redactor.secretArgument(in: input, from: input.startIndex)
        #expect(input[argument.end...] == " --verbose")
        #expect(argument.quoted == nil)
        #expect(!argument.continuesLine)
    }

    @Test(arguments: ["run --password 'synthetic value' --verbose", "run --token=syntheticValue --verbose"])
    func commandRedactionPreservesFollowingOptions(input: String) {
        var state = Redactor.StreamState()
        let output = Redactor.redactSecretOptions(input, state: &state)
        #expect(!output.contains("synthetic"))
        #expect(output.hasSuffix("[redacted:secret] --verbose"))
        #expect(state.quotedValue == nil)
    }

    @Test func shellLineContinuationRetainsPendingValue() {
        var state = Redactor.StreamState()
        #expect(Redactor.redactSecretOptions("run --password synthetic\\", state: &state) == "run --password [redacted:secret]")
        #expect(state.expectingSecretValue)
    }

    @Test func encodedQuotesCloseOnlyAtTheirMatchingEscapeDepth() throws {
        let quote = try #require(Redactor.unterminatedQuote(in: #"\"synthetic"#[...], kind: "secret"))
        let continuation = #"literal" value\" --verbose"#
        let end = try #require(Redactor.closingQuoteEnd(in: continuation[...], for: quote))
        #expect(continuation[end...] == " --verbose")
        #expect(quote.escapeDepth == 1)
    }

    @Test func serializedArgumentsPreserveSiblingsAndPendingValues() {
        var state = Redactor.StreamState()
        let output = Redactor.redactSerializedOptions(#"["--password", "synthetic value", "--verbose"]"#, state: &state)
        #expect(output == #"["--password", [redacted:secret], "--verbose"]"#)
        #expect(!state.expectingSecretValue)
        _ = Redactor.redactSerializedOptions(#"["--password","#, state: &state)
        #expect(state.expectingSecretValue)
    }
}
