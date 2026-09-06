import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlineTests {
    @Test(arguments: [#"{\\"password\\":\\"synthetic\\"}"#, #"{\\"Authorization\\":\\"synthetic\\"}"#])
    func encodedFieldKeysIdentifyTheirValues(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("synthetic"))
    }



    @Test(arguments: ["Cookie: session=syntheticOpaque", "Set-Cookie: session=syntheticOpaque; HttpOnly"])
    func cookieHeadersConcealTheWholeSessionValue(_ input: String) {
        var state = Redactor.StreamState()
        #expect(!Redactor.applyPatterns(to: input, codeExpected: false, state: &state).contains("syntheticOpaque"))
    }

    @Test(arguments: ["password", "Authorization", "device_code"], ["\"", "\\\""])
    func completeFieldsBoundInlineOwnership(label: String, quote: String) {
        var state = Redactor.StreamState()
        let input = label + ": " + quote + "synthetic" + quote + ", status: ready"
        let output = Redactor.applyPatterns(to: input, codeExpected: false, state: &state)
        #expect(!output.contains("synthetic"))
        #expect(output.contains("status: ready"))
        #expect(!state.expectingSecretValue && !state.expectingAuthorizationValue && !state.expectingDeviceCode)
    }

    @Test(arguments: ["password:", "Authorization:", "device_code:"])
    func initialExplicitValuesArmTheirNextLine(_ label: String) {
        var state = Redactor.StreamState()
        let output = Redactor.applyPatterns(to: label + " \"synthetic\" \\", codeExpected: false, state: &state)
        #expect(!output.contains("synthetic"))
        #expect(state.expectingSecretValue || state.authorizationValueIsOnTheNextLine || state.expectingDeviceCode)
    }

    @Test func ordinaryDiagnosticsStayUnchanged() {
        var state = Redactor.StreamState()
        let line = "process exited with code 1; status: ready"
        #expect(Redactor.applyPatterns(to: line, codeExpected: false, state: &state) == line)
    }
}
