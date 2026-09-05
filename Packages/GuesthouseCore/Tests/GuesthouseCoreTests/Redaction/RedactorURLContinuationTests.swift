import Testing
@testable import GuesthouseCore

@Suite struct RedactorURLContinuationTests {
    @Test func anUnclosedNestedFrameCannotReleaseUserInfo() {
        var state = Redactor.StreamState()
        let first = Redactor.applyPatterns(to: "URL (https://user:first(partial)", codeExpected: false, state: &state)
        #expect(!first.contains("first(partial"))
        #expect(Redactor.applyPatterns(to: "opaque@example.com", codeExpected: false, state: &state)
                == "[redacted:userinfo]@example.com")
    }

    @Test(arguments: [("\"", "\""), ("'", "'"), ("(", ")"), ("<", ">")], ["https://", "//", #"https:\/\/"#])
    func aCompleteOuterFrameProvesTheURLCannotContinue(frame: (String, String), prefix: String) {
        var state = Redactor.StreamState()
        let input = "URL " + frame.0 + prefix + "example.com:443" + frame.1
        #expect(Redactor.applyPatterns(to: input, codeExpected: false, state: &state) == input)
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
