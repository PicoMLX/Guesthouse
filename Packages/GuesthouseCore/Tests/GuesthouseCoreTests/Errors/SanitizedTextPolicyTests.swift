import Foundation
import Testing
@testable import GuesthouseCore

struct SanitizedTextPolicyTests {
    @Test(arguments: 0...3)
    func truncatedBasicCredentialsDoNotDependOnBase64Alignment(padding: Int) {
        let credential = Data(("user:" + String(repeating: "syntheticPassword", count: 100)).utf8).base64EncodedString()
        let output = SanitizedText(String(repeating: " ", count: padding) + "Basic " + credential).value
        #expect(!output.contains(String(credential.prefix(12))))
    }

    @Test(arguments: ["user:", "dsn=user:", "prefix user:"])
    func truncatedUnclassifiedColonValuesCannotExposeDSNPasswords(prefix: String) {
        let output = SanitizedText(prefix + String(repeating: "syntheticPassword", count: 100) + "@tcp(host)/db").value
        #expect(!output.contains("synthetic"))
        #expect(SanitizedText("compiler: ordinary diagnostic").value == "compiler: ordinary diagnostic")
    }

    @Test(arguments: ["\u{00A0}", "\u{2007}", "\t", "\n", "\u{2028}"])
    func competingRawAndNormalizedCredentialReadingsFailClosed(separator: String) {
        let output = SanitizedText("ghp_" + separator + "syntheticCredential").value
        #expect(!output.contains("synthetic"))
        #expect(output == "[redacted:normalized-value]")
    }

    @Test func disagreementCannotReleaseAnotherCredentialFoundOnlyByTheRawReading() {
        let output = SanitizedText("--password\tsyntheticValue ghp_\u{00A0}syntheticToken").value
        #expect(!output.contains("synthetic"))
    }

    @Test(arguments: ["//user:", "url=//user:", "(//user:", #"url=\/\/user:"#])
    func networkPathCredentialsBeyondTheInspectionWindowStayPrivate(prefix: String) {
        let input = prefix + String(repeating: "syntheticSecret", count: 150) + "@host/path"
        #expect(!SanitizedText(input).value.contains("synthetic"))
    }

    @Test(arguments: ["\t", "\n", "\r", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"], ["--password", "Bearer"])
    func controlWhitespaceRemainsACredentialBoundary(separator: String, label: String) {
        let output = SanitizedText(label + separator + "syntheticValue").value
        #expect(!output.contains("synthetic"))
    }

    @Test(arguments: ["passx\u{08}word: ", "passx\u{1B}[Dword: ", "passx\u{9B}Dword: "])
    func cursorCorrectionsRetainTheirFollowingCredential(label: String) {
        #expect(!SanitizedText(label + "syntheticValue").value.contains("synthetic"))
    }

    @Test func standaloneValueClampsAndSanitizesBeforeEncoding() throws {
        let value = SanitizedText("password: opaqueValue", limit: .max)
        #expect(!value.value.contains("opaqueValue"))
        #expect(!String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("opaqueValue"))
        #expect(SanitizedText("hello", limit: .min).value == "h…")
        #expect(SanitizedText(String(repeating: "x", count: 5_000), limit: .max).value.unicodeScalars.count == SanitizedText.maximumLimit + 1)
    }

    @Test func standaloneDecodeReappliesTheSamePolicy() throws {
        let input = Data("\"password: opaqueValue\"".utf8)
        let decoded = try JSONDecoder().decode(SanitizedText.self, from: input)
        #expect(decoded == SanitizedText("password: opaqueValue", limit: .max))
        #expect(!decoded.value.contains("opaqueValue"))
    }
}
