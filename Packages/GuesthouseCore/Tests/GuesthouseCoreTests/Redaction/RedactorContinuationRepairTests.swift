import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactorContinuationRepairTests {
    private let redactor = Redactor()

    @Test(arguments: [2, 4, 6], ["\"", "'"])
    func prefixedEvenSlashParametersCloseAtRawQuotes(depth: Int, quote: String) {
        let output = redactor.redact(lines: ["password: prefix=" + String(repeating: "\\", count: depth)
            + quote + "syntheticValue" + quote, "Finished"]).map(\.text)
        #expect(!output[0].contains("syntheticValue"))
        #expect(output[1] == "Finished")
    }

    @Test(arguments: ["artifact", "artifact_", "artifact-"])
    func anUnambiguousFilenamePrefixBeforeIncompleteJOSEStaysVisible(prefix: String) {
        #expect(redactor.redact(prefix + "eyJhbGciOiJIUzI1NiJ9.syntheticPayload") == prefix + "[redacted:jwt]")
    }

    @Test(arguments: ["ghp_", "sk-proj-"])
    func otherTokenMarkersDoNotDestroyIncompleteJOSEEvidence(prefix: String) {
        let output = redactor.redact(lines: [prefix + "eyJhbGciOiJIUzI1NiJ9.syntheticPayload",
            ".syntheticSignature", "[status] Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "[status] Finished")
    }

    @Test func namedCompetingHeadersRemainSensitiveAcrossPhysicalLines() {
        let header = "eyJhbGciOiJIUzI1NiJ9"
        let output = redactor.redact(lines: [header + "." + header + ".syntheticPayload",
            ".syntheticSignature", "[status] Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "[status] Finished")
    }

    @Test func aFinalJWTSignatureSegmentCanItselfWrapAgain() {
        let output = redactor.redact(lines: ["eyJhbGciOiJIUzI1NiJ9.payload", ".syntheticSignaturePartOne",
            "syntheticSignaturePartTwo", "[status] Finished", "Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(Array(output.suffix(2)) == ["[status] Finished", "Finished"])
    }

    @Test(arguments: [2, 4, 6], ["\"", "'"])
    func evenSlashShellOpenersUseOrdinaryQuoteClosers(depth: Int, quote: String) {
        let input = "run --password " + String(repeating: "\\", count: depth) + quote + "synthetic value" + quote + " --verbose"
        let output = redactor.redact(lines: [input, "Finished"]).map(\.text)
        #expect(output[0] == "run --password [redacted:secret] --verbose")
        #expect(output[1] == "Finished")
    }

    @Test(arguments: ["Bearer", "Bearer \\", "Bearer syntheticFirst\\", "Bearer syntheticFirst \\"])
    func valueLessAndContinuedBearerSchemesProtectTheNextRecord(first: String) {
        let output = redactor.redact(lines: [first, "syntheticCredential", "Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["", "artifact", "session."])
    func jwtWrappingBeforeTheFinalSegmentRemainsSensitive(prefix: String) {
        let header = "eyJhbGciOiJIUzI1NiJ9"
        let output = redactor.redact(lines: [prefix + header + ".eyJzdWIiOiIxMjM0In0", ".syntheticSignature", "[status] Finished"]).map(\.text)
        #expect(!output.joined().contains(header))
        #expect(!output.joined().contains("syntheticSignature"))
        #expect(output[2] == "[status] Finished")
    }

    @Test func aQuotedJWTBoundaryDoesNotConsumeTheFollowingDiagnostic() {
        let output = redactor.redact(lines: ["password: \"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0", ".syntheticSignature\"", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticSignature"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [1, 2, 3, 4], ["", "artifact", "session."])
    func everyIncompleteJWESegmentCountCarriesContinuation(count: Int, prefix: String) {
        let segments = ["eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0", "wrappedKey", "iv", "syntheticCiphertext", "syntheticTag"]
        let output = redactor.redact(lines: [prefix + segments.prefix(count).joined(separator: ".") + ".",
            segments.dropFirst(count).joined(separator: "."), "[status] Finished"]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "[status] Finished")
    }

    @Test(arguments: ["Bearer syntheticComplete", "Bearer syntheticComplete \\\\",
                      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.syntheticSignature"])
    func completedCredentialsDoNotArmAnotherPhysicalRecord(input: String) {
        #expect(redactor.redact(lines: [input, "Finished"]).last?.text == "Finished")
    }

    @Test(arguments: ["build.manifest", "eyJzdWIiOiIxMjM0In0.release", "artifact.2026."])
    func ordinaryDotSeparatedValuesDoNotBecomeWrappedJWTs(input: String) {
        #expect(redactor.redact(lines: [input, "Finished"]).map(\.text) == [input, "Finished"])
    }

    @Test(arguments: [
        "run --password --token --verbose",
        "run --password --token=syntheticValue --verbose",
        #"["--password", "--token", "--verbose"]"#,
        #"["--password", "--token", "syntheticValue", "--verbose"]"#,
    ])
    func ambiguousOptionNamesAreAlsoPossiblePasswords(input: String) {
        let output = redactor.redact(input)
        #expect(!output.contains("--token"))
        #expect(!output.contains("syntheticValue"))
        #expect(output.contains("--password"))
    }

    @Test(arguments: ["run --password", "run --password --token"])
    func bareOptionsStillArmTheCompletePublicAPI(input: String) {
        let output = redactor.redact(lines: [input, "syntheticNextValue", "Finished"]).map(\.text)
        #expect(output[1] == "[redacted:secret]")
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [
        #"Enter the code: "syntheticFirst""#,
        #"Your code is "syntheticFirst""#,
        "Enter the code AB12CD34",
        "Your code is AB12CD34",
    ])
    func promptsPreserveAnExplicitContinuationOutsideTheValue(prompt: String) {
        let output = redactor.redact(lines: [prompt + " \\", "syntheticSecond", "Finished"]).map(\.text)
        #expect(!output[0].contains("syntheticFirst"))
        #expect(output[1] == "[redacted:device-code]")
        #expect(output[2] == "Finished")
        let completed = redactor.redact(lines: [prompt + " \\\\", "Finished"]).map(\.text)
        #expect(completed[1] == "Finished")
    }

    @Test(arguments: ["supported code HMAC-SHA256", "the code uses CHACHA20-POLY1305"])
    func mentioningCodeDoesNotTurnAnAlgorithmIntoACredential(input: String) {
        #expect(redactor.redact(input) == input)
        #expect(!redactor.redact("user_code: " + input).contains("SHA256"))
        #expect(!redactor.redact("Enter the code: " + input).contains("POLY1305"))
    }

    @Test(arguments: ["Authorization: Custom token=", "password: prefix token=", "user_code: prefix value="])
    func unquotedPrefixesDoNotHideAnOpenQuotedParameter(prefix: String) {
        let output = redactor.redact(lines: [
            prefix + "\"syntheticFirst", "syntheticSecond\"", "Finished",
        ]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["Authorization: Custom token=", "password: prefix token="], ["\"", "'", #"\""#])
    func closingAParameterDoesNotEndItsEnclosingFold(prefix: String, quote: String) {
        let output = redactor.redact(lines: [
            prefix + quote + "syntheticFirst", "syntheticSecond" + quote,
            " syntheticThird", "Finished",
        ]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[3] == "Finished")
    }

    @Test func anApostropheInsideAnUnquotedWordDoesNotOpenAQuote() {
        #expect(redactor.redact(lines: ["password: don't-copy-this-synthetic-value", "Finished"]).last?.text == "Finished")
    }

    @Test(arguments: ["Authorization: Custom first", "password: first"])
    func whitespaceOnlyLinesDoNotCloseAnEstablishedFold(first: String) {
        let output = redactor.redact(lines: [first, " \t ", " syntheticSecond", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticSecond"))
        #expect(output[3] == "Finished")
    }

    @Test func aPEMFooterInsideTheClosingQuoteStillEndsTheBlock() {
        let output = redactor.redact(lines: [
            "password: \"-----BEGIN PRIVATE KEY-----", "syntheticKeyBody",
            "-----END PRIVATE KEY-----\"", "Finished",
        ]).map(\.text)
        #expect(!output.joined().contains("syntheticKeyBody"))
        #expect(output[3] == "Finished")
    }

    @Test(arguments: ["PRIVATE KEY", "RSA PRIVATE KEY"], [false, true])
    func aPEMFooterInsideAQuoteCanOpenTheNextBlock(label: String, closeImmediately: Bool) {
        let output = redactor.redact(lines: [
            "password: \"-----BEGIN PRIVATE KEY-----", "syntheticFirstBody",
            "-----END PRIVATE KEY----- -----BEGIN \(label)-----" + (closeImmediately ? "\"" : ""),
            closeImmediately ? "syntheticSecondBody" : "close\"", "syntheticThirdBody",
            "-----END \(label)-----", "Finished",
        ]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[6] == "Finished")
    }
}
