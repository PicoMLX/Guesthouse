import Testing
@testable import GuesthouseCore

@Suite struct RedactorRetainedContextTests {
    @Test(arguments: [
        ("x\u{1B}Authorization: opaque", "x Authorization: opaque"),
        ("x\u{1B}password: opaque", "x password: opaque"),
        ("x\u{1B}[--password opaque", "x --password opaque"),
        ("x\u{1B}device_code: opaque", "x device_code: opaque"),
        ("☃x\u{1B}pass\u{1B}word: opaque", "☃x password: opaque")
    ])
    func recoveredFieldsHonorControlSuppliedBoundaries(_ input: String, _ context: String) {
        #expect(Redactor.renderings(of: input).contexts.contains(context))
    }

    @Test(arguments: ["-password:", "-token:", "-passphrase:"])
    func recoveredTokensKeepBareCredentialContext(_ label: String) {
        let input = "eyJhbGciOiJIUzI1NiIsI\u{1B}[mtpZCI6Im5hYmMifQ.payload." + label
        let result = Redactor.renderings(of: input)
        #expect(!result.spliced.contains("payload"))
        #expect(result.contexts.contains { $0.contains(Redactor.patterns.secretLabelOnly)
            || $0.contains(Redactor.patterns.secretOptionOnly) })
    }

    @Test(arguments: ["filename", "☃filename"], ["\u{0}", "\u{7}"])
    func pendingPrefixesKeepEarlierControlBoundaries(_ prefix: String, _ control: String) throws {
        var pending: Redactor.StreamState.ControlString?
        _ = Redactor.stripTerminalEscapes(prefix + control + "s\u{1B}[31", openControlString: &pending)
        #expect(pending != nil)
        let result = Redactor.stripTerminalEscapes("mk-abcdefghijklmnop", openControlString: &pending)
        #expect(!result.spliced.contains("abcdefghijklmnop"))
        #expect(result.spliced.contains("[redacted:api-key]"))
        #expect(result.contexts.contains { $0.contains(Redactor.patterns.wrappedTokenAtLineEnd) })
        #expect(pending == nil)
    }
}
