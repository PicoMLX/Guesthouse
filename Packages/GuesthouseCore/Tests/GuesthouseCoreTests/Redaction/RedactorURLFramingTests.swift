import Testing
@testable import GuesthouseCore

@Suite struct RedactorURLFramingTests {
    @Test(arguments: ["[https://one.example, https://two.example]", "urls=[//one.example, //two.example]",
                      #""visit https://example.com""#, #""visit https://example.com:443""#])
    func provenDiagnosticFramesPreservePublicAuthorities(_ input: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.redactURLContinuations(input, state: &state) == input)
        #expect(!state.expectingURLUserInfo && state.pendingURLSlashes == 0)
        #expect(Redactor.redactURLContinuations("Finished", state: &state) == "Finished")
    }

    @Test(arguments: ["https://user:opaque", "(https://user:opaque)", "'https://user:opaque'",
                      #""visit https://user:opaque\""#])
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
