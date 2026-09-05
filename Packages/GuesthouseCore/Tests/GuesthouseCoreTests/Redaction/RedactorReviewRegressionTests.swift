import Foundation
import Testing
@testable import GuesthouseCore

/// Review regressions and combinations of previously fixed input forms. Every credential is
/// generated from synthetic fixture text; no provider-issued tokens or encryption keys are used.
@Suite struct RedactorReviewRegressionTests {
    let redactor = Redactor()

    @Test(arguments: ["private_key", "privateKey", "private-key", "private key"], [
        "{label}: {value}",
        "payload.{label}={value}",
        #"{"{label}":"{value}"}"#,
        "{'{label}':'{value}'}",
        #"payload={\"{label}\":\"{value}\"}"#,
        "> logger /credentials/{label}: {value}",
    ])
    func privateKeyFieldsRemoveInlineValues(label: String, template: String) {
        let secret = "reviewOpaqueValue"
        let input = template.replacing("{label}", with: label).replacing("{value}", with: secret)
        let output = redactor.redact(input)
        #expect(!output.contains(secret))
        #expect(output.contains("[redacted:secret]"))
    }

    @Test(arguments: ["private_key", "privateKey", "private-key", "private key"], [
        "{label}:",
        "payload.{label}=",
        "  \"{label}\":",
        "{'{label}':",
        #"payload={\"{label}\":"#,
        "> logger /credentials/{label}=",
    ])
    func privateKeyFieldsRetainContextAcrossBlankLines(label: String, template: String) {
        let input = template.replacing("{label}", with: label)
        let output = redactor.redact(lines: [input, "", "\u{1B}[0m", "\"reviewOpaqueValue\"", "Finished"]).map(\.text)
        #expect(output[0].contains("[redacted:secret]"))
        #expect(output[1] == "")
        #expect(output[2] == "")
        #expect(output[3] == "[redacted:secret]")
        #expect(output[4] == "Finished")
    }

    @Test(arguments: [
        "private_key: \"",
        "payload.privateKey= '",
        #"payload={\"private_key\":\""#,
    ])
    func privateKeyOpeningQuotesKeepTheNextValuePending(label: String) {
        let closing = label.hasSuffix(#"\""#) ? #"\""# : String(label.suffix(1))
        let output = redactor.redact(lines: [label, "", "\u{1B}[0m", "reviewOpaqueValue" + closing, "Finished"]).map(\.text)
        #expect(output[0].contains("[redacted:secret]"))
        #expect(output[1] == "")
        #expect(output[2] == "")
        #expect(output[3] == "[redacted:secret]")
        #expect(output[4] == "Finished")
    }

    @Test(arguments: ["--private_key", "--privateKey", "--private-key", "--signing-private-key"], [
        "reviewOpaqueValue", "\"reviewOpaqueValue with spaces\"", "'reviewOpaqueValue with spaces'",
    ])
    func privateKeyOptionsKeepFollowingArguments(option: String, value: String) {
        #expect(redactor.redact("run \(option) \(value) --verbose")
            == "run \(option) [redacted:secret] --verbose")
    }

    @Test(arguments: [
        "payload.Authorization:",
        "/request/Authorization=",
        "> Authorization:",
        "[debug] Authorization=",
        #"payload={\"Authorization\":"#,
        "[debug] 'Authorization'=",
        "payload.Auth\u{1B}[0morization:",
    ], ["Basic cmV2aWV3OnN5bnRoZXRpYw==", "Custom reviewOpaqueValue"])
    func prefixedAuthorizationLabelsConsumeUnindentedValues(label: String, value: String) {
        let output = redactor.redact(lines: [label, "", "\u{1B}[0m", value, "Accept: */*", "Finished"]).map(\.text)
        #expect(output[0].contains("[redacted:authorization]"))
        #expect(output[1] == "")
        #expect(output[2] == "")
        #expect(output[3] == "[redacted:authorization]")
        #expect(output[4] == "Accept: */*")
        #expect(output[5] == "Finished")
    }

    @Test(arguments: [
        "payload.Authorization: \"",
        "> 'Authorization'= '",
        #"payload={\"Authorization\":\""#,
    ], ["Basic cmV2aWV3OnN5bnRoZXRpYw==", "Custom reviewOpaqueValue"])
    func authorizationOpeningQuotesKeepTheNextValuePending(label: String, value: String) {
        let closing = label.hasSuffix(#"\""#) ? #"\""# : String(label.suffix(1))
        let output = redactor.redact(lines: [label, "", "\u{1B}[0m", value + closing, "Finished"]).map(\.text)
        #expect(output[0].contains("[redacted:authorization]"))
        #expect(output[1] == "")
        #expect(output[2] == "")
        #expect(output[3] == "[redacted:authorization]")
        #expect(output[4] == "Finished")
    }

    @Test(arguments: ["payload.Authorization:", "> 'Authorization'=", "/request/Authorization:"])
    func prefixedAuthorizationContextEndsAtTheNextHeader(label: String) {
        let output = redactor.redact(lines: [label, "Accept: */*", "Finished"]).map(\.text)
        #expect(output[0].contains("[redacted:authorization]"))
        #expect(output[1] == "Accept: */*")
        #expect(output[2] == "Finished")
    }

    @Test(arguments: [
        ("Your one-time code is abcdef", "abcdef"),
        ("Your one-time code is xy", "xy"),
        ("Your one-time code is 7", "7"),
        ("Your one-time code is \"abcdef\"", "abcdef"),
        ("Your one-time code is 'xy'", "xy"),
        (#"Your one-time code is \"abcdef\""#, "abcdef"),
        ("The verification code equals lowercase", "lowercase"),
        ("Your pairing code reads ab.cd", "ab.cd"),
    ])
    func declarativeCodeValuesAreOpaque(input: String, value: String) {
        let output = redactor.redact(input)
        #expect(output.contains("[redacted:device-code]"))
        #expect(!output.contains(value))
    }

    @Test(arguments: ["", " \"", " '", #" \""#], ["abcdef", "\"abcdef", "'abcdef", #"\"abcdef"#])
    func declarativeCodePromptsKeepTheNextValuePending(promptSuffix: String, value: String) {
        let closing = promptSuffix.isEmpty ? String(value.prefix { $0 == "\\" || $0 == "\"" || $0 == "'" })
            : promptSuffix.trimmingCharacters(in: .whitespaces)
        let output = redactor.redact(lines: ["Your one-time code is" + promptSuffix, "", "\u{1B}[0m", value + closing, "Finished"]).map(\.text)
        #expect(output[1] == "")
        #expect(output[2] == "")
        #expect(output[3] == "[redacted:device-code]")
        #expect(output[4] == "Finished")
    }

    @Test(arguments: [
        "The login code was rejected",
        "Enter the code shown below",
        "process exited with code 1",
        "verification code delivery failed",
    ])
    func codeDiagnosticsDoNotConsumeTheNextLine(input: String) {
        #expect(redactor.redact(lines: [input, "Build failed"]).map(\.text) == [input, "Build failed"])
    }

    @Test(arguments: [
        (#"{"alg":"RSA-OAEP","enc":"A256GCM"}"#, "wrappedSyntheticKey"),
        (#"{"alg":"dir","enc":"A256GCM"}"#, ""),
        (" {\n\"enc\": \"A256GCM\", \"alg\": \"dir\"\n}", ""),
    ], [
        ("", ""), ("cache_", ".partial.tmp"), ("session.", ".log"), ("/tmp/", "/result"),
    ])
    func encryptedTokensRemoveAllFiveSegments(headerAndKey: (String, String), surroundings: (String, String)) {
        let token = Self.encryptedToken(header: headerAndKey.0, key: headerAndKey.1)
        let input = surroundings.0 + token + surroundings.1
        #expect(redactor.redact(input) == surroundings.0 + "[redacted:jwt]" + surroundings.1)
    }

    @Test func adjacentSignedAndEncryptedTokensAreIndependentlyRemoved() {
        let encrypted = Self.encryptedToken(header: #"{"alg":"dir","enc":"A256GCM"}"#, key: "")
        let signed = [Self.base64url(#"{"alg":"HS256"}"#), Self.base64url("synthetic claims"), Self.base64url("synthetic signature")].joined(separator: ".")
        #expect(redactor.redact("cache.\(encrypted).\(signed).\(encrypted).tmp")
            == "cache.[redacted:jwt].[redacted:jwt].[redacted:jwt].tmp")
    }

    @Test(arguments: ["docs.example.com.build.log", "cache.release.1.2.3.tmp", "com.apple.dt.Xcode"])
    func ordinaryDottedNamesArePreserved(input: String) {
        #expect(redactor.redact(input) == input)
    }

    @Test(arguments: ["public_key: reviewPublicValue", "keyboard: plain", "privateKeyCount: 2"])
    func ordinaryKeyLabelsArePreserved(input: String) {
        #expect(redactor.redact(input) == input)
    }

    /// These pairings combine previously fixed forms so a shared label vocabulary cannot fix
    /// private keys by accidentally dropping camel-case, environment, quoted, or spaced keys.
    @Test(arguments: [
        (#"{"accessToken":"reviewOpaqueValue"}"#, "accessToken"),
        ("GUESTHOUSE_REFRESH_TOKEN=reviewOpaqueValue", "TOKEN"),
        ("payload.'client secret': 'reviewOpaqueValue'", "client secret"),
        (#"payload={\"api_key\":\"reviewOpaqueValue\"}"#, "api_key"),
    ])
    func existingSecretLabelSpellingsStillRedact(input: String, label: String) {
        let output = redactor.redact(input)
        #expect(!output.contains("reviewOpaqueValue"))
        #expect(output.contains(label))
        #expect(output.contains("[redacted:secret]"))
    }

    private static func encryptedToken(header: String, key: String) -> String {
        [base64url(header), base64url(key), base64url("synthetic iv"),
         base64url("synthetic ciphertext"), base64url("synthetic authentication tag")].joined(separator: ".")
    }

    private static func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
