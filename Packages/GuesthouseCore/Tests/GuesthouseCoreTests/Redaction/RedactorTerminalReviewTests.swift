import Testing
@testable import GuesthouseCore

@Suite struct RedactorTerminalReviewTests {
    @Test(arguments: ["\u{1B}[", "\u{009B}"], [Character("m"), "e", "1"])
    func aCSIIntroducerCannotConsumeAJOSEHeaderCharacter(introducer: String, character: Character) throws {
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

    @Test(arguments: [("\u{1B}]0;", "\u{07}"), ("\u{1B}P", "\u{1B}\\")])
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
