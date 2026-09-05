import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactorTerminalContextRepairTests {
    @Test(arguments: ["\u{1B}[31", "\u{009B}31", "\u{1B}[1;31"])
    func parameterizedCSIRequiresAFinalByteOnlyReading(introducer: String) {
        let input = "eyJhbGciOiJIUzI1NiIsI" + introducer + "mtpZCI6Im5hYmMifQ.payload.syntheticSignature"
        #expect(!Redactor().redact(input).contains("syntheticSignature"))
    }

    @Test(arguments: ["\u{0000}", "\u{1B}[31m", "\u{0008}"])
    func networkPathUserinfoRetainsItsControlBoundary(control: String) {
        let input = "filename" + control + "//sample:syntheticPassword@example.com"
        #expect(!Redactor().redact(input).contains("syntheticPassword"))
    }

    @Test func renormalizingASpliceDoesNotDiscardTheRemainingLine() {
        let first = Redactor.renderings(of: "filename\u{0000}sk-abcdefghijklmnopqrstuvwx")
        #expect(Redactor.renderings(of: first.spliced).joined == first.joined)
    }

    @Test(arguments: ["\u{0000}", "\u{1B}[31m"])
    func contextFreeDeviceCodeMatchingRetainsControlBoundaries(control: String) throws {
        let input = "prefix" + control + "AB12-CD34"
        #expect(!Redactor().redact(untrusted: input).contains("AB12-CD34"))
        #expect(!Redactor().redact(fieldValue: input).contains("AB12-CD34"))
        // A log without a code context retains the previous conservative shape-only policy.
        #expect(Redactor().redact(input) == "prefixAB12-CD34")
        #expect(Redactor().redact(untrusted: "prefix" + control + "HMAC-SHA256") == "prefixHMAC-SHA256")
    }

    @Test(arguments: ["\u{0000}", "\u{1B}[31m"])
    func terminalBoundariesArmShortWrappedKeys(control: String) {
        let output = Redactor().redact(lines: [
            "filename" + control + "sk-abcdefgh", "syntheticContinuation", "Finished normally",
        ]).map(\.text)
        #expect(!output[0].contains("sk-abcdefgh"))
        #expect(!output[1].contains("syntheticContinuation"))
    }

    @Test(arguments: ["\u{0000}", "\u{1B}[31m"])
    func closingQuoteSuffixesKeepTheirTerminalOptionBoundary(control: String) {
        let output = Redactor().redact(lines: [
            "password: \"syntheticFirst", "syntheticLast\" filename" + control + "--password",
            "syntheticNextValue", "Finished",
        ]).map(\.text)
        #expect(!output.joined().contains("synthetic"))
        #expect(output[3] == "Finished")
    }

    @Test(arguments: [
        "pass\u{1B}[word: ", "Author\u{1B}[ization: Custom ", "run --pass\u{1B}[word ",
        "Enter the co\u{1B}[de: ", "user_co\u{1B}[de: ",
        #"["--pass"# + "\u{1B}[" + #"word", "#,
    ])
    func recoveredContextLabelsHideOpaqueValues(prefix: String) {
        #expect(!Redactor().redact(prefix + "syntheticValue").contains("syntheticValue"))
    }

    @Test(arguments: ["pass\u{1B}[word:", "Author\u{1B}[ization:", "run --pass\u{1B}[word", "Enter the co\u{1B}[de:"])
    func recoveredContextLabelsAlsoProtectTheFollowingLine(opener: String) {
        let output = Redactor().redact(lines: [opener, "syntheticNextValue", "Finished"]).map(\.text)
        #expect(!output.joined().contains("syntheticNextValue"))
        #expect(output[2] == "Finished")
    }

    @Test func recoveredPEMOpenersProtectTheWholeBlock() {
        let output = Redactor().redact(lines: [
            "-----BE\u{1B}[GIN PRIVATE KEY-----", "syntheticKeyBody",
            "-----END PRIVATE KEY-----", "Finished",
        ]).map(\.text)
        #expect(!output.joined().contains("syntheticKeyBody"))
        #expect(output[3] == "Finished")
    }

    @Test(arguments: ["\u{1B}[PuTTY-", "PuTTY-\u{1B}[User-Key-File-3:", "PuTTY-\u{1B}[31User-Key-File-3:"])
    func recoveredPPKOpenersAdvanceFramingOnce(opener: String) {
        let header = opener == "\u{1B}[PuTTY-" ? opener + "User-Key-File-3:" : opener
        let output = Redactor().redact(lines: [
            header + " ssh-rsa", "Private-Lines: 2", "c3ludGhldGlj", "Ym9keQ==",
            "Private-MAC: " + String(repeating: "a", count: 64), "Finished",
        ]).map(\.text)
        #expect(output.dropLast().allSatisfy { $0 == "[redacted:private-key]" })
        #expect(output[5] == "Finished")
    }

    @Test func controlStringPayloadsNeverBecomeRecoveredContext() {
        let input = "before\u{1B}]password: syntheticValue\u{7} after"
        #expect(Redactor().redact(lines: [input, "Finished"]).map(\.text) == ["before after", "Finished"])
    }

    @Test(arguments: ["password: \"", "pass\u{1B}[word: \""], [false, true])
    func aPPKOpenerPreservesItsEnclosingCredential(prefix: String, insidePEM: Bool) {
        let output = Redactor().redact(lines: [
            prefix + (insidePEM ? "-----BEGIN PRIVATE KEY----- " : "") + "PuTTY-User-Key-File-3: ssh-rsa",
            "Private-Lines: 1", "c3ludGhldGlj", "Private-MAC: " + String(repeating: "a", count: 64),
            "syntheticContinuation" + (insidePEM ? "-----END PRIVATE KEY-----" : "") + "\"", "Finished",
        ]).map(\.text)
        #expect(!output.joined().contains("syntheticContinuation"))
        #expect(output[5] == "Finished")
    }
}
