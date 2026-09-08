import Testing
@testable import GuesthouseCore

@Suite struct RedactorCommandContainerTests {
    @Test(arguments: [
        (#"args=["--password syntheticOpaque"]"#, #"args=["--password [redacted:secret]"]"#),
        (#"args=["run --password syntheticOpaque"]"#, #"args=["run --password [redacted:secret]"]"#),
        ("args=['run --password syntheticOpaque']", "args=['run --password [redacted:secret]']"),
        (#"args=["first", "run --password syntheticOpaque"]"#, #"args=["first", "run --password [redacted:secret]"]"#),
        (#"args=["run '--password syntheticOpaque' --verbose"]"#, #"args=["run '--password [redacted:secret]' --verbose"]"#),
        (#"args=['run "--password syntheticOpaque" --verbose']"#, #"args=['run "--password [redacted:secret]" --verbose']"#),
        (#"args=["run 'public' --password syntheticOpaque"]"#, #"args=["run 'public' --password [redacted:secret]"]"#)
    ])
    func containerCommandQuotesCloseWithoutPendingState(_ input: String, _ expected: String) {
        var state = Redactor.StreamState()
        #expect(Redactor.redactSecretOptions(input, state: &state) == expected)
        #expect(state.quotedValue == nil)
        #expect(!state.expectingSecretValue && !state.secretValueExplicitlyContinues)
    }

    @Test(arguments: [(#"args=["--password syntheticFirst"#, Character("\"")),
                      (#"args=["run --password syntheticFirst"#, Character("\"")),
                      ("args=['run --password syntheticFirst", Character("'"))])
    func unfinishedContainerCommandsRetainQuoteState(_ input: String, _ delimiter: Character) throws {
        var state = Redactor.StreamState()
        #expect(!Redactor.redactSecretOptions(input, state: &state).contains("syntheticFirst"))
        let quote = try #require(state.quotedValue)
        #expect(quote.delimiter == delimiter && quote.escapeDepth == 0 && quote.kind == "secret")
        #expect(!quote.singleQuotesAreLiteral)
    }
}
