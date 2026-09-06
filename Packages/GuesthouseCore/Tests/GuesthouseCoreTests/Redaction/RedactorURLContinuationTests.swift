import Testing
@testable import GuesthouseCore

@Suite struct RedactorURLContinuationTests {
    @Test(arguments: [("https:/", "/user:syntheticOpaque@host/path"), ("https:", "//user:syntheticOpaque@host/path"),
                      ("/", "/user:syntheticOpaque@host/path"), ("url=https:\\/", "\\/user:syntheticOpaque@host/path")])
    func partialAuthorityDelimitersRetainUserinfo(_ parts: (String, String)) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: parts.0, codeExpected: false, state: &state)
        #expect(!Redactor.applyPatterns(to: parts.1, codeExpected: false, state: &state).contains("syntheticOpaque"))
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    @Test(arguments: [2, 3, 16, 256])
    func nestedSlashEscapesKeepCompleteAndContinuedUserInfoPrivate(_ depth: Int) {
        let slash = String(repeating: "\\", count: depth) + "/"
        let prefix = "https:" + slash + slash
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: prefix + "user:syntheticOpaque@example.com/path", codeExpected: false, state: &state)
            == prefix + "[redacted:userinfo]@example.com/path")
        #expect(!state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: prefix + "user:syntheticFirst", codeExpected: false, state: &state)
            == prefix + "[redacted:userinfo]")
        #expect(state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: "syntheticSecond@example.com/path", codeExpected: false, state: &state)
            == "[redacted:userinfo]@example.com/path")
        #expect(!state.expectingURLUserInfo)
    }

    @Test func bearerFragmentsArmAnOrdinaryFoldWithoutDemandingTheNextRecord() {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: "Bearer syntheticFirst", codeExpected: false, state: &state)
            == "Bearer [redacted:bearer-token]")
        #expect(state.expectingAuthorizationValue)
        #expect(!state.authorizationValueIsOnTheNextLine)
        #expect(!state.authorizationValueExplicitlyContinues)
    }

    @Test(arguments: ["cloning https://opaqueCredential", "//opaqueCredential", #"url=https:\/\/opaqueCredential"#, "https://"])
    func usernameOnlyAuthorityPrefixesRetainTheirFollowingCredential(_ input: String) {
        var state = Redactor.StreamState()
        let first = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(!first.contains("opaqueCredential"))
        #expect(state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: "anotherFragment", codeExpected: false, state: &state) == "[redacted:userinfo]")
        #expect(Redactor.applyPatterns(to: "@example.com/repo", codeExpected: false, state: &state)
                == "[redacted:userinfo]@example.com/repo")
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    @Test(arguments: [#"URL "https://example.com""#, "URL <https://example.com>", "https://example.com/path", "https://example.com?query", "https://example.com#fragment"])
    func completedHostOnlyURLsStillHaveAProvenBoundary(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(!state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    @Test func anUnclosedNestedFrameCannotReleaseUserInfo() {
        var state = Redactor.StreamState()
        let first = Redactor.applyPatterns(to: "URL (https://user:first(partial)", codeExpected: false, state: &state)
        #expect(!first.contains("first(partial"))
        #expect(Redactor.applyPatterns(to: "opaque@example.com", codeExpected: false, state: &state)
                == "[redacted:userinfo]@example.com")
    }

    @Test(arguments: [("\"", "\""), ("<", ">")], ["https://", "//", #"https:\/\/"#])
    func aCompleteOuterFrameProvesTheURLCannotContinue(frame: (String, String), prefix: String) {
        var state = Redactor.StreamState()
        let input = "URL " + frame.0 + prefix + "example.com:443" + frame.1
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    // Parentheses and apostrophes are URI sub-delimiters, not proof of closure.
    @Test(arguments: [("(", ")"), ("'", "'")], ["user:opaque", "example.com:443"])
    func apparentFramesCannotReleaseAValidUserinfoContinuation(frame: (String, String), authority: String) {
        var state = Redactor.StreamState()
        let first = Redactor.applyPatterns(to: frame.0 + "https://" + authority + frame.1, codeExpected: false, state: &state)
        #expect(!first.contains(authority))
        #expect(state.expectingURLUserInfo)
        #expect(Redactor.applyPatterns(to: "@example.com/path", codeExpected: false, state: &state)
                == "[redacted:userinfo]@example.com/path")
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    @Test func ambiguousBarePortsCannotReleaseAPossibleNumericPassword() {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: "https://example.com:443", codeExpected: false, state: &state)
                == "https://[redacted:userinfo]")
        #expect(Redactor.applyPatterns(to: "@real.example/repo", codeExpected: false, state: &state)
                == "[redacted:userinfo]@real.example/repo")
    }

    @Test func blankRecordsAndEmbeddedAtSignsDoNotReleasePasswordFragments() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "https://user:", codeExpected: false, state: &state)
        #expect(Redactor.applyPatterns(to: "  ", codeExpected: false, state: &state) == "  ")
        #expect(Redactor.applyPatterns(to: "  p@ss@example.com/repo", codeExpected: false, state: &state)
                == "  [redacted:userinfo]@example.com/repo")
    }

    @Test(arguments: ["cloning https://user:", "//user:", #"url=https:\/\/user:"#])
    func wrappedUserInfoRemainsSensitiveUntilItsAuthorityCloses(_ prefix: String) {
        var state = Redactor.StreamState()
        let first = Redactor.applyPatterns(to: prefix + "firstFragment", codeExpected: false, state: &state)
        let second = Redactor.applyPatterns(to: "middleFragment", codeExpected: false, state: &state)
        let third = Redactor.applyPatterns(to: "lastFragment@example.com/repo", codeExpected: false, state: &state)
        #expect(!first.contains("firstFragment"))
        #expect(!second.contains("middleFragment"))
        #expect(third == "[redacted:userinfo]@example.com/repo")
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    @Test func aPasswordDelimiterAloneArmsTheNextRecord() {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "cloning https://user:", codeExpected: false, state: &state)
        #expect(Redactor.applyPatterns(to: "opaque@example.com", codeExpected: false, state: &state)
                == "[redacted:userinfo]@example.com")
    }

    @Test(arguments: ["/path", "?query=public", "#fragment"])
    func aProvenAuthorityBoundaryEndsTheContinuation(_ suffix: String) {
        var state = Redactor.StreamState()
        _ = Redactor.applyPatterns(to: "https://user:", codeExpected: false, state: &state)
        #expect(Redactor.applyPatterns(to: "opaque" + suffix, codeExpected: false, state: &state)
                == "[redacted:userinfo]" + suffix)
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }

    @Test(arguments: ["https://example.com:443/path", "https://example.com?email=user@example.org",
                      "https://[::1]:443/path"])
    func completeNonCredentialAuthoritiesKeepTheirSuffixes(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
        #expect(Redactor.applyPatterns(to: "Finished", codeExpected: false, state: &state) == "Finished")
    }
}
