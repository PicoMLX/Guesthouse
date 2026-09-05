import Testing
@testable import GuesthouseCore

@Suite struct RedactorQuotedValueTests {
    @Test func encodedValuesPreserveKeysAndAvoidInputPlaceholderCollisions() {
        let input = #"\"status\":\"ready\", "# + "\"\u{E001}0\u{E002}\""
        let protected = Redactor.protectEncodedQuotedValues(in: input) { ($0, .init()) }
        #expect(protected.values["0"] == nil)
        #expect(protected.values["1"] == #"\"ready\""#)
        var state = Redactor.StreamState()
        #expect(protected.restoring(in: protected.text, state: &state) == input)
    }

    @Test(arguments: [#"\"value\"tail"#, #"\"value\" tail"#])
    func ambiguousTailsAreNotClosedFields(_ value: String) {
        #expect(!Redactor.isClosedQuotedValue(value[...]))
        #expect(Redactor.protectEncodedQuotedValues(in: value) { ($0, .init()) }.values.isEmpty)
    }

    @Test func removedValuesDoNotRestorePendingContexts() {
        let protected = Redactor.protectEncodedQuotedValues(in: #"\"value\""#) { value in
            var state = Redactor.StreamState()
            state.expectingSecretValue = true
            return (value, state)
        }
        var state = Redactor.StreamState()
        #expect(protected.restoring(in: "[redacted:secret]", state: &state) == "[redacted:secret]")
        #expect(!state.expectingSecretValue)
        _ = protected.restoring(in: protected.text, state: &state)
        #expect(state.expectingSecretValue)
    }
}
