import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactorParserReviewTests {
    @Test func rawSingleQuotesCloseAfterLiteralBackslashes() {
        let input = #"'synthetic\' --verbose"#
        let argument = Redactor.secretArgument(in: input, from: input.startIndex)
        #expect(input[argument.end...] == " --verbose")
        #expect(argument.quoted == nil)
        var state = Redactor.StreamState()
        #expect(Redactor.redactSecretOptions("--password " + input, state: &state) == "--password [redacted:secret] --verbose")
        #expect(state.quotedValue == nil)
    }

    @Test func rawSingleQuoteContinuationKeepsShellSemantics() throws {
        let opening = "'synthetic"
        let quote = try #require(Redactor.secretArgument(in: opening, from: opening.startIndex).quoted)
        let continuation = #"literal\' --verbose"#
        let end = try #require(Redactor.closingQuoteEnd(in: continuation[...], for: quote))
        #expect(continuation[end...] == " --verbose")
    }

    @Test(arguments: [1, 3])
    func encodedBackslashPairsDoNotHideClosingQuotes(depth: Int) throws {
        let opening = String(repeating: "\\", count: depth) + "\""
        let escaped = String(repeating: "\\", count: 2 * depth + 1) + "\""
        let closing = String(repeating: "\\", count: 3 * depth + 2) + "\""
        let value = "synthetic" + escaped + "interior" + closing
        var state = Redactor.StreamState()
        let input = "--password " + opening + value + " --token " + opening + "other" + opening
        #expect(Redactor.redactSecretOptions(input, state: &state) == "--password [redacted:secret] --token [redacted:secret]")
        #expect(state.quotedValue == nil)
        #expect(!state.expectingSecretValue)
        let quote = Redactor.StreamState.QuotedValue(delimiter: "\"", escapeDepth: depth, kind: "secret")
        let continuation = value + " --verbose"
        let end = try #require(Redactor.closingQuoteEnd(in: continuation[...], for: quote))
        #expect(continuation[end...] == " --verbose")
    }

    @Test(arguments: ["--token", "--token="])
    func aBareFollowingOptionKeepsItsPendingValue(option: String) {
        var state = Redactor.StreamState()
        let input = "run --password " + option
        // The second option is also a possible opaque password, while its value stays pending.
        #expect(Redactor.redactSecretOptions(input, state: &state) == "run --password [redacted:secret]")
        #expect(state.expectingSecretValue)
    }

    @Test(arguments: [("\\", true), ("Bearer \\", true), ("synthetic\\\\\\ \t", true),
                      ("synthetic\\\\", false), (#"'synthetic\\'"#, false), (#""synthetic""#, false)])
    func onlyOddTrailingBackslashesContinueValues(input: String, expected: Bool) {
        #expect(Redactor.valueStartsOnNextLine(input[...]) == expected)
    }

    @Test func serializedApostrophesRetainEscapedContents() throws {
        var state = Redactor.StreamState()
        let input = #"['--password', 'first\'secretTail', '--verbose']"#
        #expect(Redactor.redactSerializedOptions(input, state: &state) == #"['--password', [redacted:secret], '--verbose']"#)
        _ = Redactor.redactSerializedOptions(#"['--password', 'first\'secretTail"#, state: &state)
        let quote = try #require(state.quotedValue)
        let continuation = #"still\'privateTail', '--verbose']"#
        let end = try #require(Redactor.closingQuoteEnd(in: continuation[...], for: quote))
        #expect(continuation[end...] == #", '--verbose']"#)
    }

    @Test(arguments: [
        ("H.partial.H.payload.signature", "M.M"),
        ("E.partial.E..iv.cipher.tag.tmp", "M.M.tmp"),
        ("E.H.iv.cipher.tag.tmp", "M.M.tmp"),
        ("H.e30.signature.tmp", "M.tmp"),
        ("artifactE..iv.cipher.tag.tmp", "artifactM.tmp"),
    ])
    func overlappingJOSEHeadersKeepEverySecretSegmentCovered(input: String, expected: String) {
        let input = input.replacingOccurrences(of: "H", with: "eyJhbGciOiJIUzI1NiJ9")
            .replacingOccurrences(of: "E", with: "eyJlbmMiOiJBMjU2R0NNIn0")
        #expect(Redactor.redactedJWT(input[...]) == expected.replacingOccurrences(of: "M", with: "[redacted:jwt]"))
    }
}
