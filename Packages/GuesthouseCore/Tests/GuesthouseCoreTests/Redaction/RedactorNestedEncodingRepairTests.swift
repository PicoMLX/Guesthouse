import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactorNestedEncodingRepairTests {
    @Test(arguments: 2...5)
    func nestedEncodedFieldsStillConcealTheirOpaqueValues(layers: Int) throws {
        var input = #"{"password":"syntheticCredential","note":"ordinaryValue"}"#
        for _ in 0..<layers { input = String(decoding: try JSONEncoder().encode(input), as: UTF8.self) }
        let output = Redactor().redact("payload: " + input + "\nFinished")
        #expect(!output.contains("syntheticCredential"))
        #expect(output.hasSuffix("\nFinished"))
    }

    @Test(arguments: 2...5)
    func nestedOrdinaryValuesDoNotBecomeCredentials(layers: Int) throws {
        var input = #"{"note":"ordinaryValue","count":42}"#
        for _ in 0..<layers { input = String(decoding: try JSONEncoder().encode(input), as: UTF8.self) }
        #expect(Redactor().redact(input) == input)
    }

    @Test func excessiveNestingIsConcealedInsteadOfRecursingWithoutABound() throws {
        var input = #"{"note":"syntheticDeepValue"}"#
        for _ in 0..<11 { input = String(decoding: try JSONEncoder().encode(input), as: UTF8.self) }
        let output = Redactor().redact(input + "\nFinished")
        #expect(!output.contains("syntheticDeepValue"))
        #expect(output.hasSuffix("\nFinished"))
    }

    @Test func layerDecodingDoesNotCreatePhysicalLineTerminators() {
        #expect(Redactor.removingQuotedEncodingLayer(#"a\nb\rc\td"#) == #"a\nb\rc\td"#)
    }

    @Test func manyNestedSiblingsStayIndependent() throws {
        let value = String(decoding: try JSONEncoder().encode(#"{"password":"syntheticValue"}"#), as: UTF8.self)
        let input = Array(repeating: "\"payload\": " + value, count: 200).joined(separator: ", ")
        #expect(!Redactor().redact(input).contains("syntheticValue"))
    }
}
