import Testing
@testable import GuesthouseCore

@Suite struct RedactorURLFramingTests {
    @Test(arguments: [("<", ">"), ("{", "}"), ("`", "`"), ("\"", "\"")])
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
