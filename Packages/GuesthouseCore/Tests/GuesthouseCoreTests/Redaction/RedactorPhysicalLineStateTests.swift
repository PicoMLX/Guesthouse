import Testing
@testable import GuesthouseCore

@Suite struct RedactorPhysicalLineStateTests {
    @Test(arguments: [("Authorization: Custom first", "authorization"), ("password: first", "secret")],
          ["\"", "'", "\\\""])
    func nestedQuoteClosurePreservesTheOuterFold(field: (String, String), quote: String) {
        let lines = [field.0, " token=" + quote + "syntheticFirst", "syntheticSecond" + quote,
                     " syntheticThird", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[3] == "[redacted:\(field.1)]")
        #expect(output[4] == "done")
        #expect(Redactor().redact(lines.joined(separator: "\r\n")) == output.joined(separator: "\r\n"))
    }

    @Test(arguments: [("Authorization:", "authorization"), ("password: first", "secret")],
          [" syntheticFirst", " \"syntheticFirst\"", " \\\"syntheticFirst\\\""])
    func explicitFoldContinuesOntoAnUnindentedPhysicalLine(field: (String, String), value: String) {
        let lines = [field.0, value + " \\", "", "syntheticSecond\\", "syntheticThird", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "")
        #expect(output[3] == "[redacted:\(field.1)]")
        #expect(output[4] == "[redacted:\(field.1)]")
        #expect(output[5] == "done")
    }

    @Test(arguments: [("Authorization:", "authorization"), ("password:", "secret"), ("device_code:", "device-code")],
          ["\"", "'", "\\\""])
    func closingAMultilineQuoteRetainsItsExplicitContinuation(field: (String, String), quote: String) {
        let lines = [field.0 + " " + quote + "syntheticFirst", "syntheticSecond" + quote + " \\",
                     "\u{1B}[0m", "syntheticThird", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "")
        #expect(output[3] == "[redacted:\(field.1)]")
        #expect(output[4] == "done")
    }

    @Test(arguments: [("Authorization:", "authorization"), ("password:", "secret")])
    func evenBackslashesDoNotContinueACompletedQuotedValue(field: (String, String)) {
        let lines = [field.0, " \"syntheticFirst\" \\\\", " status: ready", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(output[1] == "[redacted:\(field.1)]")
        #expect(Array(output.dropFirst(2)) == Array(lines.dropFirst(2)))
    }

    @Test func aNestedQuoteClosureAlsoKeepsItsFollowingPendingField() {
        let lines = ["Authorization: Custom first", " token=\"syntheticFirst", "syntheticSecond\" password:",
                     "syntheticThird", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[3] == "[redacted:secret]")
        #expect(output[4] == "done")
    }

    @Test(arguments: [("Authorization: Custom first", "authorization"), ("password: first", "secret")])
    func successiveNestedQuotesKeepTheSameOuterFold(field: (String, String)) {
        let lines = [field.0, " token=\"syntheticFirst", "syntheticSecond\" token=\"syntheticThird",
                     "syntheticFourth\"", " syntheticFifth", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[4] == "[redacted:\(field.1)]")
        #expect(output[5] == "done")
    }

    @Test(arguments: ["Authorization:", "password:", "device_code:"])
    func aWholeMultilineQuotedValueReleasesStructuredSiblings(field: String) {
        let lines = [field + " \"syntheticFirst", "syntheticSecond\",", " status: ready", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(Array(output.dropFirst(2)) == Array(lines.dropFirst(2)))
    }

    @Test(arguments: [
        ["Authorization:", " \"syntheticFirst\" \\"],
        ["Authorization: \"syntheticFirst", "syntheticSecond\" \\"],
    ])
    func anExplicitAuthorizationContinuationOwnsHeaderShapedValues(prefix: [String]) {
        let output = Redactor().redact(lines: prefix + ["", "synthetic:Secret", "done"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(Array(output.suffix(3)) == ["", "[redacted:authorization]", "done"])
    }

    @Test func anEmptyAuthorizationLabelStillReleasesAnOrdinaryHeader() {
        let output = Redactor().redact(lines: ["Authorization:", "Accept: */*", "done"]).map(\.text)
        #expect(Array(output.suffix(2)) == ["Accept: */*", "done"])
    }

    @Test func contextUnionRetainsBothEnclosingFoldsAndExplicitContinuation() {
        var state = Redactor.StreamState()
        state.quotedValue = .init(delimiter: "\"", escapeDepth: 0, kind: "secret", enclosingAuthorizationFold: true)
        var scanned = Redactor.StreamState()
        scanned.quotedValue = .init(delimiter: "'", escapeDepth: 0, kind: "secret", enclosingSecretFold: true)
        scanned.authorizationValueExplicitlyContinues = true
        scanned.secretValueExplicitlyContinues = true
        Redactor.mergePendingContexts(from: scanned, into: &state)
        #expect(state.quotedValue?.delimiter == "\"")
        #expect(state.quotedValue?.enclosingAuthorizationFold == true)
        #expect(state.quotedValue?.enclosingSecretFold == true)
        #expect(state.authorizationValueExplicitlyContinues)
        #expect(state.secretValueExplicitlyContinues)
    }

    @Test(arguments: [("Authorization: Custom first", "authorization"), ("password: first", "secret")],
          [[" \"syntheticFirst\""], [" \"syntheticFirst", "syntheticSecond\""],
           [" syntheticFirst\\", "\"syntheticSecond\""], [" syntheticFirst\\", "\"syntheticSecond", "syntheticThird\""]])
    func leadingQuotedFragmentsDoNotTerminateAnEstablishedFold(field: (String, String), fragment: [String]) {
        let lines = [field.0] + fragment + [" syntheticLast", "done"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(Array(output.suffix(2)) == ["[redacted:\(field.1)]", "done"])
    }
}
