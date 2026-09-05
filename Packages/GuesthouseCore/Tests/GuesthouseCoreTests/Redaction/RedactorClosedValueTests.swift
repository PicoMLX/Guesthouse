import Testing
@testable import GuesthouseCore

/// Synthetic credentials distinguish completed structured fields from values that still fold.
@Suite struct RedactorClosedValueTests {
    @Test(arguments: [("Authorization", "Basic dXNlcjpwYXNz", "authorization"), ("password", "syntheticValue", "secret")],
          ["\"", "'", "\\\"", "\\'"])
    func completedQuotedFieldsPreserveIndentedSiblings(field: (String, String, String), quote: String) {
        let lines = ["{", "  \(quote)\(field.0)\(quote): \(quote)\(field.1)\(quote),",
                     #"  "status": "ready","#, #"  "path": "/tmp/report""#, "}"]
        let output = Redactor().redact(lines: lines).map(\.text)
        #expect(!output[1].contains(field.1))
        #expect(output[1].contains("[redacted:\(field.2)]"))
        #expect(Array(output.dropFirst(2)) == Array(lines.dropFirst(2)))
        #expect(Redactor().redact(lines.joined(separator: "\n")) == output.joined(separator: "\n"))
    }

    @Test(arguments: [("Authorization", "authorization"), ("password", "secret")],
          ["syntheticValue", "\"syntheticValue", "\\\"syntheticValue", "", "\""])
    func unfinishedValuesStillRedactTheirContinuation(field: (String, String), value: String) {
        let output = Redactor().redact(lines: [field.0 + ": " + value, "", "  syntheticContinuation"]).map(\.text)
        #expect(!output[0].contains("syntheticValue"))
        #expect(output[1] == "")
        #expect(output[2] == "[redacted:\(field.1)]")
    }

    @Test(arguments: ["Authorization", "password"], ["\"\"", "''", "\\\"\\\""])
    func completedEmptyQuotedFieldsDoNotConsumeTheNextLine(field: String, value: String) {
        let output = Redactor().redact(lines: [field + ": " + value, "  status: ready"]).map(\.text)
        #expect(output[1] == "  status: ready")
    }
}
