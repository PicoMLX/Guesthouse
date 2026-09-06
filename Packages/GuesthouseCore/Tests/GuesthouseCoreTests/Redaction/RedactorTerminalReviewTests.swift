import Testing
@testable import GuesthouseCore

@Suite struct RedactorTerminalReviewTests {
    @Test(arguments: ["remote=", "url=", "--remote="])
    func assignedURLCredentialsRetainTheirOwnOpener(_ assignment: String) {
        let value = assignment + "//sample:syntheticPassword@example.com"
        let result = Redactor.renderings(of: "ghp_abcdefghijklmnopqrstuvwx\u{0}" + value)
        #expect(result.spliced.contains(Redactor.splicedBoundary + value))
        #expect(!result.spliced.contains("abcdefghijklmnopqrstuvwx" + assignment))
    }

    @Test func networkPathCredentialsRetainAControlSuppliedBoundary() {
        let result = Redactor.renderings(of: "filename\u{0}//sample:syntheticPassword@example.com")
        #expect(result.spliced.contains(Redactor.splicedBoundary + "//sample:syntheticPassword@example.com"))
    }

    @Test func adjacentGenericAPIKeysRetainTheirOwnOpener() {
        let result = Redactor.renderings(of: "ghp_abcdefghijklmnopqrstuvwx\u{0}sk-qrstuvwxyzabcdef")
        #expect(result.spliced.contains(Redactor.splicedBoundary + "sk-qrstuvwxyzabcdef"))
        #expect(!result.spliced.contains("abcdefghijklmnopqrstuvwx"))
    }

    @Test(arguments: [("\u{1B}]", "\u{7}"), ("\u{1B}P", "\u{1B}\\"),
                      ("\u{1B}_", "\u{9C}"), ("\u{1B}^", "\u{9C}"), ("\u{1B}X", "\u{9C}")],
          ["\r", "\n", "\r\n"])
    func wholeTextNormalizationPreservesOpaqueRecordFraming(parts: (String, String), separator: String) {
        #expect(Redactor.stripTerminalEscapes("before" + parts.0 + "title" + separator + "payload" + parts.1 + "after")
            == "before" + separator + "after")
    }
    @Test(arguments: ["\u{1B}--pass\u{1B}[31word syntheticOpaque",
                      "\u{1B}--passw\u{1B}[31ord syntheticOpaque"])
    func independentlyRecoveredOptionsRemainContexts(_ input: String) {
        #expect(Redactor.renderings(of: input).contexts.contains("--password syntheticOpaque"))
    }

    @Test func aSwallowedPEMHeaderRetainsItsBoundary() {
        let pem = "-----BEGIN PRIVATE KEY-----syntheticBody"
        let result = Redactor.renderings(of: "sk-abcdefghijklmnop\u{0}" + pem)
        #expect(result.spliced.contains(Redactor.splicedBoundary + pem))
        #expect(!result.spliced.contains("abcdefghijklmnop"))
    }

    @Test func contextualCodesRecoveredFromCommandsKeepOnlyTheirValuePrivate() {
        let result = Redactor.renderings(of: "The login code was rejected; retry AB12-\u{1B}CD34.")
        #expect(result.spliced == "The login code was rejected; retry [redacted:device-code].")
        #expect(Redactor.renderings(of: "Build revision AB12-\u{1B}CD34.").spliced
            .replacing(Redactor.splicedBoundary, with: "") == "Build revision AB12-D34.")
    }

    @Test(arguments: ["Bearer syntheticSecond", "Basic dXNlcjpwYXNz",
                      "Digest username=sample, response=syntheticSecond", "Negotiate syntheticSecond"])
    func swallowedStandaloneAuthorizationRetainsItsBoundary(_ value: String) {
        let result = Redactor.renderings(of: "sk-abcdefghijklmnop\u{0}" + value)
        #expect(result.spliced.contains(Redactor.splicedBoundary + value))
        #expect(!result.spliced.contains("abcdefghijklmnop"))
    }

    @Test(arguments: ["--password syntheticOpaque", "--password", "--token syntheticOpaque"])
    func genericIntermediatesRemainScanOnlyOptionEvidence(_ option: String) {
        let result = Redactor.renderings(of: "\u{1B}" + option)
        #expect(result.contexts.contains(option))
        #expect(!result.joined.contains("--"))
    }

    @Test(arguments: [("s", "k-abcdefghijklmnop"), ("g", "hp_abcdefghijklmnop")],
          ["\u{1B}[31", "\u{9B}31", "\u{1B}", "\u{1B}("])
    func aPendingCommandRetainsEarlierCredentialPrefix(parts: (String, String), command: String) {
        var open: Redactor.StreamState.ControlString?
        _ = Redactor.stripTerminalEscapes(parts.0 + command, openControlString: &open)
        let second = Redactor.stripTerminalEscapes(parts.1, openControlString: &open)
        #expect(!second.spliced.contains("abcdefghijklmnop"))
        #expect(open == nil)
    }

    @Test func severalPendingCommandsCannotLoseTheCredentialPrefix() {
        var open: Redactor.StreamState.ControlString?
        _ = Redactor.stripTerminalEscapes("s\u{1B}[31", openControlString: &open)
        _ = Redactor.stripTerminalEscapes("k\u{1B}[32", openControlString: &open)
        let result = Redactor.stripTerminalEscapes("-abcdefghijklmnop", openControlString: &open)
        #expect(!result.spliced.contains("bcdefghijklmnop"))
        #expect(open == nil)
    }

    @Test(arguments: [("--pass\u{1B}word syntheticOpaque", "--password syntheticOpaque"),
                      ("--pass\u{1B}word", "--password"), ("--pass\u{1B}[\u{0}word", "--password")])
    func restoredOptionsRemainCredentialContexts(input: String, expected: String) {
        #expect(Redactor.renderings(of: input).contexts.contains(expected))
    }

    @Test(arguments: ["sk-abcdefghijklmnopqrstuvwx", "ghp_abcdefghijklmnopqrstuvwx"])
    func normalizingASpliceAgainCannotSwallowItsSuffix(token: String) {
        let first = Redactor.renderings(of: "filename\u{0}" + token).spliced
        #expect(Redactor.renderings(of: first).spliced == first)
    }

    @Test(arguments: ["\u{1B}[0m", "\u{9B}0m", "\u{1B}(B"], ["\u{301}", "\u{FE0F}"])
    func controlFinalsUseScalarRatherThanGraphemeBoundaries(control: String, suffix: String) {
        #expect(Redactor.renderings(of: "red" + control + suffix + "text").joined == "red" + suffix + "text")
    }

    @Test(arguments: [("\u{1B}[31", "m"), ("\u{9B}31", "m"), ("\u{1B}", "c"), ("\u{1B}(", "B")])
    func incompleteCommandsCannotBecomeFakeSecretValues(parts: (String, String)) {
        var open: Redactor.StreamState.ControlString?
        #expect(Redactor.stripTerminalEscapes("password: " + parts.0, openControlString: &open).joined == "password: ")
        #expect(open != nil)
        #expect(Redactor.stripTerminalEscapes(parts.1 + "syntheticPassword", openControlString: &open).joined == "syntheticPassword")
        #expect(open == nil)
    }


    @Test(arguments: ["\u{1B}[", "\u{9B}"], ["\u{0}", "\u{7}", "\u{8}", "\u{9}", "\u{7F}"])
    func ignoredCSIBytesDoNotHideRecoveredFinals(introducer: String, ignored: String) {
        let result = Redactor.renderings(of: "pass" + introducer + ignored + "word: syntheticPassword")
        #expect(result.contexts.contains("password: syntheticPassword"))
    }



    @Test(arguments: ["\u{1B}", "\u{1B}(", "\u{1B}\u{0}(", "\u{1B}(\u{0}", "\u{1B}(\u{7F}"], ["accessToken", "authorization", "user_code"])
    func genericEscapeFinalsCannotHideCredentialLabels(escape: String, label: String) {
        let input = label.prefix(1) + escape + label.dropFirst() + ": syntheticPassword"
        let result = Redactor.renderings(of: String(input))
        #expect(result.contexts.contains(label + ": syntheticPassword"))
        #expect(result.joined == label.prefix(1) + label.dropFirst(2) + ": syntheticPassword")
    }


    @Test(arguments: ["\u{1B}", "\u{1B}(\u{0}", "\u{1B}[", "\u{9B}"])
    func recoveredShortPrefixesRetainStreamEvidence(escape: String) {
        #expect(Redactor.renderings(of: "s" + escape + "k-abc").contexts.contains("sk-abc"))
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
