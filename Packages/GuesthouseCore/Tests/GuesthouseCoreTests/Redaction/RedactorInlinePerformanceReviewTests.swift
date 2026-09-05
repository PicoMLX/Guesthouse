import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactorInlinePerformanceReviewTests {
    @Test func manyEncodedFieldsDoNotRescanEveryRemainingSuffix() {
        let field = #"\"password\":\"syntheticValue\""#
        let input = Array(repeating: field, count: 1_000).joined(separator: ", ")
        let output = Redactor().redact(input)
        #expect(!output.contains("syntheticValue"))
        #expect(output.components(separatedBy: "[redacted:secret]").count == 1_001)
    }

    @Test(arguments: ["password:", "Authorization:", "device_code:", "Your code is:"], ["secretTail", " unquotedTail"])
    func ambiguousEncodedQuoteSuffixesStaySensitive(label: String, tail: String) {
        let output = Redactor().redact(label + #" \"quoted\""# + tail)
        #expect(!output.contains("quoted"))
        #expect(!output.contains(tail.trimmingCharacters(in: .whitespaces)))
    }

    @Test func ordinaryEncodedValuesStillExposeTokensToRedaction() {
        let output = Redactor().redact(#"\"status\":\"ghp_abcdefghijklmnopqrstuvwxyz\", \"path\":\"/tmp/report\""#)
        #expect(!output.contains("abcdefghijklmnopqrstuvwxyz"))
        #expect(output.contains(#"\"path\":\"/tmp/report\""#))
    }
}
