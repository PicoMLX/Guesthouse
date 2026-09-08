import Testing
@testable import GuesthouseCore

@Suite struct RedactorURLFramingTests {
    @Test func anEscapedFieldQuoteCannotOpenJSONValueQuarantine() {
        var state = Redactor.StreamState()
        let input = #"\"clientSecret\"#
        #expect(Redactor.redactURLContinuations(input, state: &state) == input)
        #expect(!state.pendingEncodedURLString && !state.encodedURLHasTrailingEscape)
    }

    @Test(arguments: ["password:", "Authorization:", "device_code:"])
    func aClosingValueQuoteCannotOpenEncodedURLQuarantine(_ label: String) {
        var state = Redactor.StreamState()
        let input = label + #" "synthetic" \"#
        #expect(Redactor.redactURLContinuations(input, state: &state) == input)
        #expect(!state.pendingEncodedURLString && !state.encodedURLHasTrailingEscape)
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func everyFirstUnicodeEscapeBoundaryIsQuarantined(_ split: Int) {
        let escape = #"\u003a"#
        var state = Redactor.StreamState()
        let first = Redactor.redactURLContinuations(#"{"url":"https"# + escape.prefix(split), state: &state)
        #expect(state.pendingEncodedURLString)
        let next = String(escape.dropFirst(split)) + #"\u002f\u002fuser:syntheticOpaque\u0040example.com/path"}"#
        let second = Redactor.redactURLContinuations(next, state: &state)
        #expect(!(first + second).contains("syntheticOpaque"))
        #expect(!state.pendingEncodedURLString && !state.encodedURLHasTrailingEscape)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: [
        [#"{"url":"https:\u002f"#, #"\u002fuser:syntheticOpaque\u0040example.com"}"#],
        [#"{"url":"https:\u002f"#, #"\u002fuser:syntheticFirst\"#, #""syntheticSecond@example.com/path"}"#],
        [#"{"url":"https\u003a\u002f"#, #"\u002Fuser:syntheticOpaque\u0040example.com/path"}"#]
    ])
    func incompleteUnicodeURLStringsRetainOnlyFramingBits(_ records: [String]) {
        var state = Redactor.StreamState()
        let output = records.map { Redactor.redactURLContinuations($0, state: &state) }.joined()
        #expect(!output.contains("synthetic"))
        #expect(!state.pendingEncodedURLString && !state.encodedURLHasTrailingEscape)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: ["/path", "?query=value", "#fragment"])
    func continuedHostOnlyAuthoritiesEndAtEveryURLTerminator(_ terminator: String) {
        var state = Redactor.StreamState()
        _ = Redactor.redactURLContinuations("https:/", state: &state)
        let next = "/example.com" + terminator
        #expect(Redactor.redactURLContinuations(next, state: &state) == next)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: [["url", "=//user:syntheticOpaque@example.com/path"],
                      ["url", "=/", "/user:syntheticOpaque@example.com/path"]])
    func continuedAssignmentsDoNotNeedTheirNameOnTheSameRecord(_ input: [String]) {
        var state = Redactor.StreamState()
        let result = input.map { Redactor.redactURLContinuations($0, state: &state) }.joined()
        #expect(!result.contains("syntheticOpaque"))
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: [
        #"{"url":"https://user:syntheticOpaque\u0040example.com/path"}"#,
        #"{"url":"https:\u002f\u002Fuser:syntheticOpaque@example.com/path"}"#,
        #"{"url":"https\u003a\u002f\u002fuser\u003asyntheticOpaque\u0040example.com\u002fpath"}"#
    ])
    func unicodeEncodedURLStructureStillConcealsUserinfo(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.redactURLContinuations(input, state: &state)
            == #"{"url":"https://[redacted:userinfo]@example.com/path"}"#)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
    }

    @Test(arguments: [#"{"url":"https:\u002f\u002fexample.com/path"}"#,
                      #"{"name":"pass\u0077ord"}"#, #"{"message":"ordinary \u0040 character"}"#])
    func nonCredentialUnicodeStringsKeepTheirOriginalEncoding(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.redactURLContinuations(input, state: &state) == input)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
    }

    @Test(arguments: [
        (["[https:/", "/[2001:db8::1],//user:syntheticOpaque@example.com]"]),
        (["[https:/", "/[2001:db8::1],//user:syntheticFirst", "syntheticSecond@example.com/path]"]),
        ([#"prefix "https://user:syntheticFirst"#, #"syntheticSecond\"syntheticThird@example.com/path""#]),
        ([#"prefix "https://user:syntheticFirst\"#, #""syntheticThird@example.com/path""#]),
        ([#"[https://one.example,/"#, #"/user:syntheticOpaque@example.com]"#]),
        ([#"[https://one.example,\/"#, #"\/user:syntheticOpaque@example.com]"#])
    ])
    func continuedEscapedQuotesAndCompactListsConcealEveryCredential(_ records: [String]) {
        var state = Redactor.StreamState()
        let output = records.map { Redactor.redactURLContinuations($0, state: &state) }.joined()
        #expect(!output.contains("synthetic"))
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: [("<", ">"), ("{", "}"), ("`", "`"), ("\"", "\""), ("[", "]")])
    func continuedHostOnlyFramesReleaseTheFollowingRecord(_ opener: String, _ closer: String) {
        var state = Redactor.StreamState()
        let first = "prefix " + opener + "https:/"
        #expect(Redactor.redactURLContinuations(first, state: &state) == first)
        #expect(state.pendingURLSlashes == 1)
        #expect(Redactor.redactURLContinuations("/example.com" + closer, state: &state) == "/example.com" + closer)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: [">", "}", "`", "\""])
    func continuedFramedUserinfoStillConcealsEveryCredential(_ closer: String) {
        var state = Redactor.StreamState()
        _ = Redactor.redactURLContinuations("https://user:syntheticFirst", state: &state)
        #expect(Redactor.redactURLContinuations("syntheticSecond@example.com" + closer, state: &state)
            == "[redacted:userinfo]@example.com" + closer)
        #expect(!state.expectingURLUserInfo)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: [["https://user:syntheticFirst@", "syntheticSecond@example.com/path"],
                      ["https://user:syntheticFirst@", "syntheticMiddle@", "syntheticSecond@example.com/path"],
                      ["https://user:syntheticFirst", "syntheticMiddle@syntheticStill", "syntheticLast@example.com/path"],
                      ["https://user:syntheticFirst@syntheticMiddle", "syntheticLast@example.com/path"]])
    func intermediateAtSignsRetainUserinfoAcrossRecords(_ records: [String]) {
        var state = Redactor.StreamState()
        let output = records.map { Redactor.redactURLContinuations($0, state: &state) }.joined()
        #expect(!output.contains("synthetic"))
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: [("[https://user:sec,ret@example.com]", "[https://[redacted:userinfo]@example.com]"),
                      ("[//user:sec,ret@one.example,//other:opaque@two.example]", "[//[redacted:userinfo]@one.example,//[redacted:userinfo]@two.example]")])
    func commasInsideUserinfoAreNotListSeparators(_ input: String, _ expected: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.redactURLContinuations(input, state: &state) == expected)
        #expect(!state.expectingURLUserInfo)
    }

    @Test(arguments: [
        ("https://user:first@one/path,//user:second@two/path", "https://[redacted:userinfo]@one/path,//[redacted:userinfo]@two/path"),
        ("url=https://user:first@one/path,//user:second@two/path", "url=https://[redacted:userinfo]@one/path,//[redacted:userinfo]@two/path"),
        ("[url=//one:alpha@one.example,url=//two:bravo@two.example]", "[url=//[redacted:userinfo]@one.example,url=//[redacted:userinfo]@two.example]"),
        ("[https://[2001:db8::1],//user:bravo@[2001:db8::2]]", "[https://[2001:db8::1],//[redacted:userinfo]@[2001:db8::2]]")
    ])
    func assignedAndIPv6ListElementsKeepTheirOwnAuthority(_ input: String, _ expected: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.redactURLContinuations(input, state: &state) == expected)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
    }

    @Test(arguments: ["[https://one.example, https://two.example]", "urls=[//one.example, //two.example]",
                      #""visit https://example.com""#, #""visit https://example.com:443""#,
                      #"prefix "https://example.com""#, #"prefix "url=https://example.com""#,
                      "prefix <url=https://example.com>", #"prefix "--url=//example.com""#,
                      "{url=https://example.com}", "prefix {url=//example.com}",
                      "prefix `https://example.com`", "prefix `//example.com`",
                      "prefix <https://example.com>, status=ok", "prefix <https://example.com>,status=ok",
                      "prefix `https://example.com`,status=ok"])
    func provenDiagnosticFramesPreservePublicAuthorities(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.redactURLContinuations(input, state: &state) == input)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test func backtickNetworkPathCanSplitItsSlashesAcrossRecords() {
        var state = Redactor.StreamState()
        _ = Redactor.redactURLContinuations("prefix `/", state: &state)
        #expect(state.pendingURLSlashes == 1)
        #expect(!Redactor.redactURLContinuations("/user:opaque@example.com/path`", state: &state).contains("opaque"))
        #expect(state.pendingURLSlashes == 0 && !state.expectingURLUserInfo)
    }

    @Test(arguments: ["https://user:opaque", "(https://user:opaque)", "'https://user:opaque'",
                      #""visit https://user:opaque\""#, #"prefix "https://user:opaque\""#])
    func unprovenFramesCannotReleasePotentialUserinfo(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.redactURLContinuations(input, state: &state).contains("opaque"))
        #expect(state.expectingURLUserInfo)
        #expect(Redactor.redactURLContinuations("@example.com/path", state: &state)
            == "[redacted:userinfo]@example.com/path")
        #expect(!state.expectingURLUserInfo)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: [1, 2, 16, 256])
    func escapeRunBoundariesKeepOnlyTheRemainingSlashCount(_ depth: Int) {
        let escape = String(repeating: "\\", count: depth)
        var state = Redactor.StreamState()
        _ = Redactor.redactURLContinuations("https:" + escape + "/" + escape, state: &state)
        #expect(state.pendingURLSlashes == 1)
        #expect(Redactor.redactURLContinuations("/user:opaque@example.com/path", state: &state)
            == "/[redacted:userinfo]@example.com/path")
        #expect(state.pendingURLSlashes == 0 && !state.expectingURLUserInfo)
    }
}
