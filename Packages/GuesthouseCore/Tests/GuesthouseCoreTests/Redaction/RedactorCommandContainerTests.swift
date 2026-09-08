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

    @Test(arguments: [#"args=["--password syntheticFirst"#, #"args=["run --password syntheticFirst"#,
                      "args=['run --password syntheticFirst"])
    func unfinishedContainerCommandsRetainQuoteState(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.redactSecretOptions(input, state: &state).contains("syntheticFirst"))
        #expect(state.quotedValue != nil)
    }
}
