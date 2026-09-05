import Testing
@testable import GuesthouseCore

@Suite struct RedactorTerminalReviewTests {
    @Test(arguments: ["\u{1B}[", "\u{9B}"], ["\u{0}31", "3\u{0}1", "31\u{7}", "31\u{8}", "31\u{9}", "31 \u{0}", " 31", "1 2", "? 3"])
    func embeddedControlsDoNotSplitCSI(introducer: String, body: String) {
        let result = Redactor.renderings(of: "pass" + introducer + body + "mword: syntheticPassword")
        #expect(result.joined == "password: syntheticPassword")
    }

    @Test(arguments: ["\u{1B}[", "\u{9B}"], ["\u{0}", "\u{7}", "\u{8}", "\u{9}", "\u{7F}"])
    func ignoredCSIBytesDoNotHideRecoveredFinals(introducer: String, ignored: String) {
        let result = Redactor.renderings(of: "pass" + introducer + ignored + "word: syntheticPassword")
        #expect(result.contexts.contains("password: syntheticPassword"))
    }

    @Test(arguments: ["\u{18}", "\u{1A}"])
    func cancellationIsNotAnIgnoredCSIByte(cancel: String) {
        #expect(Redactor.stripTerminalEscapes("pass\u{1B}[31" + cancel + "word: syntheticPassword") == "password: syntheticPassword")
    }

    @Test func aNewEscapeCancelsAnIncompleteCSI() {
        #expect(Redactor.stripTerminalEscapes("pass\u{1B}[31\u{1B}[0mword: syntheticPassword") == "password: syntheticPassword")
    }

    @Test(arguments: ["\u{1B}", "\u{1B}("], ["accessToken", "authorization", "user_code"])
    func genericEscapeFinalsCannotHideCredentialLabels(escape: String, label: String) {
        let input = label.prefix(1) + escape + label.dropFirst() + ": syntheticPassword"
        let result = Redactor.renderings(of: String(input))
        #expect(result.contexts.contains(label + ": syntheticPassword"))
        #expect(result.joined == label.prefix(1) + label.dropFirst(2) + ": syntheticPassword")
    }

    @Test(arguments: ["ghp_syntheticFirst", "sk-synthetic", "Bearer syntheticFirst"],
          ["password: syntheticSecond", "Authorization: syntheticSecond", "user_code: syntheticSecond", "password:"])
    func adjacentLabelsKeepTheirBoundaryWithoutReleasingTheToken(prefix: String, field: String) {
        let result = Redactor.renderings(of: prefix + "\u{0}" + field)
        #expect(result.spliced == "[redacted:secret]" + Redactor.splicedBoundary + field)
        #expect(result.joined == prefix + field)
    }

    @Test(arguments: ["ghp_syntheticFirst", "sk-syntheticFirst", "Bearer syntheticFirst"],
          ["Enter the code: syntheticSecond", "Enter the code ABCD1234", "Your code is syntheticSecond", "Enter the code"])
    func swallowedPromptsKeepTheirCredentialBoundary(prefix: String, prompt: String) {
        #expect(Redactor.renderings(of: prefix + "\u{0}" + prompt).spliced
                == "[redacted:secret]" + Redactor.splicedBoundary + prompt)
    }

    @Test(arguments: ["sk-synthetic", "Bearer syntheticFirst"], ["--password syntheticSecond", "--password"])
    func swallowedSecretOptionsRetainTheirBoundary(prefix: String, option: String) {
        #expect(Redactor.renderings(of: prefix + "\u{0}" + option).spliced
            == "[redacted:secret]" + Redactor.splicedBoundary + option)
    }

    @Test(arguments: ["\u{1B}", "\u{1B}(", "\u{1B}[", "\u{9B}"],
          [("https://sample:syntheticPassword", "@example.com"), ("https", "://sample:syntheticPassword@example.com")])
    func recoveredURLDelimitersConcealUserinfo(escape: String, fragments: (String, String)) {
        let result = Redactor.renderings(of: fragments.0 + escape + fragments.1)
        #expect(!result.spliced.contains("syntheticPassword"))
        #expect(result.spliced.hasSuffix("example.com"))
    }

    @Test(arguments: ["\u{1B}]", "\u{1B}P", "\u{1B}_", "\u{1B}^", "\u{1B}X", "\u{9D}", "\u{90}", "\u{9F}", "\u{9E}", "\u{98}"], ["\u{18}", "\u{1A}", "\u{1B}c", "\u{1B}[m"])
    func cancelledControlStringsReleaseVisibleDiagnostics(opener: String, cancel: String) {
        var open: Redactor.StreamState.ControlString?
        #expect(Redactor.stripTerminalEscapes("before" + opener + "payload" + cancel + "after", openControlString: &open).joined == "beforeafter")
        #expect(open == nil)
        _ = Redactor.stripTerminalEscapes(opener + "payload", openControlString: &open)
        #expect(Redactor.stripTerminalEscapes(cancel + "after", openControlString: &open).joined == "after")
        #expect(open == nil)
        #expect(Redactor.stripTerminalEscapes("Finished", openControlString: &open).joined == "Finished")
    }

    @Test(arguments: ["\u{1B}[", "\u{009B}", "\u{1B}", "\u{1B}("], [Character("m"), "e", "1"])
    func escapeIntroducersCannotConsumeAJOSEHeaderCharacter(introducer: String, character: Character) throws {
        let header = "eyJhbGciOiJIUzI1NiIsImtpZCI6Im5hYmMifQ"
        let position = try #require(header.firstIndex(of: character))
        let token = header[..<position] + introducer + header[position...] + ".syntheticPayload.syntheticSignature"
        var open: Redactor.StreamState.ControlString?
        let result = Redactor.stripTerminalEscapes("prefix/" + token + ".tmp", openControlString: &open)
        #expect(result.spliced == "prefix/[redacted:jwt].tmp")
        #expect(result.joined == Redactor.stripTerminalEscapes("prefix/" + token + ".tmp"))
        #expect(open == nil)
    }

    @Test func recoveryWorksBesideOrdinaryStylingAndPreservesQuotedFraming() {
        let input = #"'artifacteyJhbGci"# + "\u{1B}[31m" + "OiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.signature.tmp'"
        let result = Redactor.renderings(of: input)
        #expect(result.spliced == "'artifact[redacted:jwt].tmp'")
        #expect(Redactor.renderings(of: result.spliced).spliced == result.spliced)
    }

    @Test(arguments: [("\u{1B}]0;", "\u{07}"), ("\u{1B}P", "\u{1B}\\"),
                      ("\u{1B}_", "\u{9C}"), ("\u{1B}^", "\u{9C}"), ("\u{1B}X", "\u{9C}")])
    func recoveryNeverResurrectsControlStringPayloads(opener: String, closer: String) {
        let token = "eyJhbGciOiJIUzI1NiJ9.payload.signature"
        let result = Redactor.renderings(of: "before" + opener + token + closer + "after")
        #expect(result.joined == "beforeafter")
        #expect(result.spliced.replacing(Redactor.splicedBoundary, with: "") == "beforeafter")
    }

    @Test func actualTerminalCommandsKeepTheirOriginalMeaning() {
        let result = Redactor.renderings(of: "\u{1B}[31mred\u{1B}[0m \u{009B}2Jclear")
        #expect(result.joined == "red clear")
        #expect(result.spliced == result.joined)
    }

    @Test(arguments: [1, 3])
    func recoveredOffsetsPreserveUnicodeAndOtherTokenBoundaries(count: Int) {
        let token = "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.signature"
        let input = Array(repeating: "☃prefix\u{0}" + token + ".tmp", count: count).joined(separator: " / ")
        let result = Redactor.renderings(of: input).spliced.replacing(Redactor.splicedBoundary, with: "")
        #expect(result == Array(repeating: "☃prefix[redacted:jwt].tmp", count: count).joined(separator: " / "))
    }

    @Test func encryptedJOSERecoveryCoversAllFiveSegments() {
        let input = "eyJhbGciOiJkaXIiLCJlb\u{1B}[mMiOiJBMjU2R0NNIn0..iv.cipher.tag.tmp"
        #expect(Redactor.renderings(of: input).spliced == "[redacted:jwt].tmp")
    }

    @Test func anAlternateJWSNeverShortensNormalizedJWEProtection() {
        let input = "eyJl\u{1B}[Y\u{1B}[W\u{1B}[F\u{1B}[hbmMiOiJBMjU2R0NNIn0..iv.cipher.tag.tmp"
        #expect(Redactor.renderings(of: input).spliced == "[redacted:jwt].tmp")
    }

    @Test func recoveryKeepsTheWholeOverlappingBearerCredentialHidden() {
        let input = "Bearer eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.signature.extraSecret"
        #expect(Redactor.renderings(of: input).spliced == "[redacted:jwt]")
    }

    @Test(arguments: [("sk-abcdefghijklmnopqrstuvwx", "api-key"), ("ghp_abcdefghijklmnopqrstuvwx", "github-token")])
    func recoveryKeepsCredentialInitials(token: String, kind: String) {
        #expect(Redactor.renderings(of: "filename\u{1B}[" + token).spliced == "filename" + Redactor.splicedBoundary + "[redacted:\(kind)]")
    }

    @Test func jwtSpansDoNotProtectTheFollowingFilenameBoundary() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.payload.signature"
        let key = "sk-abcdefghijklmnopqrstuvwx"
        #expect(Redactor.renderings(of: jwt + ".filename\u{1B}[31m" + key).spliced == jwt + ".filename" + Redactor.splicedBoundary + key)
    }

    @Test func overlappingPEMProtectionIncludesTheWholeCurrentBody() {
        let input = "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload.-----BEGIN PRIVATE KEY-----syntheticBody-----END PRIVATE KEY-----"
        #expect(Redactor.renderings(of: input).spliced == "[redacted:jwt]")
    }

    @Test func publicTerminalNormalizationDoesNotPerformRedaction() throws {
        let header = "eyJhbGciOiJIUzI1NiIsImtpZCI6Im5hYmMifQ"
        let position = try #require(header.firstIndex(of: "m"))
        let input = header[..<position] + "\u{1B}[" + header[position...]
        #expect(Redactor.stripTerminalEscapes(String(input)) == header[..<position] + header[header.index(after: position)...])
    }
}
