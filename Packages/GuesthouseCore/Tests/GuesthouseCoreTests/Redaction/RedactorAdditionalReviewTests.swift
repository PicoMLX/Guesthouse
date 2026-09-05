import Foundation
import Testing
@testable import GuesthouseCore

/// Additional review regressions. All credential values and JOSE segments are synthetic.
@Suite struct RedactorAdditionalReviewTests {
    let redactor = Redactor()

    @Test(arguments: ["\"", "'", "\\\""])
    func aQuotedPendingSecretReleasesAfterItsIndentedValue(quote: String) {
        let output = redactor.redact(lines: [
            "password:", quote, " correct horse", "  battery staple", "Finished",
        ]).map(\.text)
        #expect(output[2] == "[redacted:secret]")
        #expect(output[3] == "[redacted:secret]")
        #expect(output[4] == "Finished")
    }

    @Test(arguments: ["password:", "passphrase:", "payload.privateKey="])
    func aPendingSecretKeepsRedactingItsIndentedContinuation(label: String) {
        let output = redactor.redact(lines: [
            label, " correct horse", "  battery staple", "Finished",
        ]).map(\.text)
        #expect(output[0].contains("[redacted:secret]"))
        #expect(output[1] == "[redacted:secret]")
        #expect(output[2] == "[redacted:secret]")
        #expect(output[3] == "Finished")
    }

    @Test(arguments: [
        ("password:", "\"", "[redacted:secret]"),
        ("privateKey:", "'", "[redacted:secret]"),
        ("token=", #"\""#, "[redacted:secret]"),
        ("Authorization:", "\"", "[redacted:authorization]"),
        ("Your one-time code is:", "\"", "[redacted:device-code]"),
        ("Your one-time code is", #"\""#, "[redacted:device-code]"),
    ])
    func aStandaloneOpeningQuoteDoesNotConsumePendingValueContext(label: String, quote: String, marker: String) {
        let output = redactor.redact(lines: [
            label, quote, "", "reviewNextLineValue", "Finished",
        ]).map(\.text)
        #expect(output[2] == "")
        #expect(output[3] == marker)
        #expect(output[4] == "Finished")
    }

    @Test(arguments: [
        "AWS_SECRET_ACCESS_KEY=reviewCompoundValue",
        "secretAccessKey: reviewCompoundValue",
        #"{"secret_access_key":"reviewCompoundValue"}"#,
        #"{"currentPassword":"reviewCompoundValue"}"#,
        "current_password=reviewCompoundValue",
        "newPassword: reviewCompoundValue",
        "oldPassword: reviewCompoundValue",
        "run --secret-access-key reviewCompoundValue --json",
        "run --current-password reviewCompoundValue --json",
    ])
    func compoundCredentialFieldsRemoveTheCompleteValue(input: String) {
        let output = redactor.redact(input)
        #expect(!output.contains("reviewCompoundValue"))
        #expect(output.contains("[redacted:secret]"))
    }

    @Test(arguments: [
        "AWS_SECRET_ACCESS_KEY=",
        #"{"secretAccessKey":"#,
        "payload.currentPassword:",
        "new_password:",
    ])
    func compoundCredentialFieldsRetainPendingValueContext(label: String) {
        let output = redactor.redact(lines: [label, "", "reviewCompoundValue", "Finished"]).map(\.text)
        #expect(output[0].contains("[redacted:secret]"))
        #expect(output[1] == "")
        #expect(output[2] == "[redacted:secret]")
        #expect(output[3] == "Finished")
    }

    @Test(arguments: [
        ("artifact", ".tmp"),
        ("1234", ".partial"),
        ("/tmp/snapshot", "/result"),
    ])
    func signedTokensCanDirectlyFollowFilenameCharacters(prefix: String, suffix: String) {
        #expect(redactor.redact(prefix + Self.signedToken + suffix)
            == prefix + "[redacted:jwt]" + suffix)
    }

    @Test(arguments: [
        ("artifact", "", ".tmp"),
        ("2048", "wrapped synthetic key", ".partial"),
    ])
    func encryptedTokensCanDirectlyFollowFilenameCharacters(prefix: String, wrappedKey: String, suffix: String) {
        let token = Self.encryptedToken(wrappedKey: wrappedKey)
        #expect(redactor.redact(prefix + token + suffix) == prefix + "[redacted:jwt]" + suffix)
    }

    @Test func aNumericFilenamePrefixDoesNotHideMixedSignedAndEncryptedTokens() {
        let input = "4096" + Self.encryptedToken(wrappedKey: "") + "." + Self.signedToken + ".tmp"
        #expect(redactor.redact(input) == "4096[redacted:jwt].[redacted:jwt].tmp")
    }

    @Test(arguments: 0...7, [
        #"{"alg":"HS256"}"#,
        " \n{\"alg\":\"HS256\"}\t",
        #"{"alg":"HS256","metadata":{"brace":"} and {","quoted":"\""}}"#,
    ])
    func everyBase64AlignmentFindsTheCompleteSignedHeader(prefixLength: Int, header: String) {
        let prefix = String(repeating: "7", count: prefixLength)
        let token = [Self.base64url(header), Self.base64url(#"{"sub":"synthetic"}"#),
                     Self.base64url("synthetic signature")].joined(separator: ".")
        #expect(redactor.redact(prefix + token + ".tmp") == prefix + "[redacted:jwt].tmp")
    }

    @Test(arguments: 0...7)
    func everyBase64AlignmentFindsNestedEncryptedHeaders(prefixLength: Int) {
        let prefix = String(repeating: "a", count: prefixLength)
        let header = " \n" + #"{"alg":"dir","enc":"A256GCM","metadata":{"brace":"} and {"}}"# + "\t"
        let token = [Self.base64url(header), "", Self.base64url("synthetic iv"),
                     Self.base64url("synthetic ciphertext"), Self.base64url("synthetic tag")].joined(separator: ".")
        #expect(redactor.redact(prefix + token + ".tmp") == prefix + "[redacted:jwt].tmp")
    }

    @Test(arguments: [
        "artifactrelease2026.tmp", "snapshot2048.partial", "cache.1.2.3.log", "docs.example.com",
    ])
    func ordinaryFilenamePrefixesAndDottedNamesRemainIntact(input: String) {
        #expect(redactor.redact(input) == input)
    }

    @Test(arguments: [
        (#"run --password \"correct horse\" --json"#, "run --password [redacted:secret] --json"),
        (#"run --password \'correct horse\' --json"#, "run --password [redacted:secret] --json"),
        (#"run --passphrase correct\ horse --json"#, "run --passphrase [redacted:secret] --json"),
        (#"run --passphrase correct\ horse\ battery --json"#, "run --passphrase [redacted:secret] --json"),
        (#"run --password correct\'horse --json"#, "run --password [redacted:secret] --json"),
        (#"run --password 'correct'\'' horse' --json"#, "run --password [redacted:secret] --json"),
        (#"run --password first --token \"second value\" --json"#, "run --password [redacted:secret] --token [redacted:secret] --json"),
    ])
    func escapedCLIValuesAreConsumedThroughTheirActualEnd(input: String, expected: String) {
        #expect(redactor.redact(input) == expected)
    }

    @Test(arguments: [
        ("//user:hunter2@example.com/repo", "//[redacted:userinfo]@example.com/repo"),
        (#"\/\/user:hunter2@example.com\/repo"#, #"\/\/[redacted:userinfo]@example.com\/repo"#),
        ("cloning //user:hunter2@example.com/repo?ref=main", "cloning //[redacted:userinfo]@example.com/repo?ref=main"),
    ])
    func protocolRelativeCredentialURLsLoseOnlyUserinfo(input: String, expected: String) {
        #expect(redactor.redact(input) == expected)
    }

    @Test(arguments: [
        "//example.com/repo/user@example.org",
        "//example.com?email=user@example.org",
        "//example.com#user@example.org",
        "https://example.com/repo/user@example.org",
        "https://example.com?next=//user@example.org",
        "//example.com?next=//user@example.org",
        #"\/\/example.com\/repo\/user@example.org"#,
    ])
    func anOrdinaryURLPathQueryOrFragmentDoesNotBecomeUserinfo(input: String) {
        #expect(redactor.redact(input) == input)
    }

    @Test(arguments: ["\u{0}", "\u{7}", "\u{8}", "\u{B}", "\u{C}", "\u{1F}", "\u{7F}", "\u{1B}[31m", "\u{9B}31m"], [
        ("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", "[redacted:github-token]", 12),
        ("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", "[redacted:github-token]", 28),
        ("sk-proj-abcdefghijklmnopqrstuvwxyz0123", "[redacted:api-key]", 12),
        ("sk-proj-abcdefghijklmnopqrstuvwxyz0123", "[redacted:api-key]", 28),
    ])
    func bareTerminalControlsCannotLeaveTokenFragments(control: String, fixture: (String, String, Int)) {
        let split = fixture.0.index(fixture.0.startIndex, offsetBy: fixture.2)
        let interrupted = fixture.0[..<split] + control + fixture.0[split...]
        #expect(redactor.redact("output " + interrupted + ".tmp") == "output " + fixture.1 + ".tmp")
    }

    @Test(arguments: ["\u{0}", "\u{8}", "\u{7F}", "\u{1B}[31m", "\u{9B}31m"], [12, 28])
    func controlsBeforeAndWithinAPIKeysCannotLeaveTokenFragments(control: String, offset: Int) {
        let token = "sk-proj-abcdefghijklmnopqrstuvwxyz0123"
        let split = token.index(token.startIndex, offsetBy: offset)
        let interrupted = "prefix" + control + token[..<split] + control + token[split...] + ".tmp"
        #expect(redactor.redact(interrupted) == "prefix[redacted:api-key].tmp")
    }

    @Test(arguments: ["\tBuild succeeded", "\t\tSources compiled"])
    func ordinaryTabIndentationSurvivesTerminalControlStripping(input: String) {
        #expect(redactor.redact(input) == input)
    }

    private static var signedToken: String {
        [base64url(#"{"alg":"HS256"}"#), base64url(#"{"sub":"synthetic"}"#), base64url("synthetic signature")]
            .joined(separator: ".")
    }

    private static func encryptedToken(wrappedKey: String) -> String {
        let header = wrappedKey.isEmpty
            ? #"{"alg":"dir","enc":"A256GCM"}"#
            : #"{"alg":"RSA-OAEP","enc":"A256GCM"}"#
        return [base64url(header), base64url(wrappedKey), base64url("synthetic iv"),
                base64url("synthetic ciphertext"), base64url("synthetic authentication tag")].joined(separator: ".")
    }

    private static func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
