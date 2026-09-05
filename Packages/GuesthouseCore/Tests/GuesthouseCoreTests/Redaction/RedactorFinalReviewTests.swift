import Foundation
import Testing
@testable import GuesthouseCore

/// Final review regressions use synthetic credentials and preserve surrounding diagnostics.
@Suite struct RedactorFinalReviewTests {
    let redactor = Redactor()

    @Test(arguments: [
        "sk-proj-abcdefghijklmnopqrstuvwxyz0123",
        "sk-svcacct-abcdefghijklmnopqrstuvwxyz0123",
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123",
    ], ["artifact", "2048"])
    func distinctiveAPIKeyPrefixesAreRecognizedInsideFilenames(token: String, prefix: String) {
        #expect(redactor.redact(prefix + token + ".tmp") == prefix + "[redacted:api-key].tmp")
    }

    @Test(arguments: [
        "risk-averse-approach-taken", "task-project-snapshot.tmp", "artifactrelease2026.tmp",
    ])
    func ordinaryWordsRemainIntactWhenAPIKeyBoundariesAreRelaxed(input: String) {
        #expect(redactor.redact(input) == input)
    }

    @Test(arguments: ["\"", "'", #"\""#], [
        ("password: ", "[redacted:secret]"),
        ("Authorization: ", "[redacted:authorization]"),
        ("device_code: ", "[redacted:device-code]"),
        ("Your one-time code is: ", "[redacted:device-code]"),
    ])
    func quotedCredentialsContinueAcrossUnindentedLinesUntilTheirClosingQuote(quote: String, field: (String, String)) {
        let lines = [field.0 + quote + "correct horse", "battery staple" + quote, "Finished"]
        let output = redactor.redact(lines: lines).map(\.text)
        #expect(output[0].contains(field.1))
        #expect(!output[0].contains("correct horse"))
        #expect(output[1] == field.1)
        #expect(output[2] == "Finished")
        #expect(redactor.redact(lines.joined(separator: "\n")) == output.joined(separator: "\n"))
    }

    @Test(arguments: [
        #"{"proxyAuthorization":"Basic dXNlcjpwYXNz"}"#,
        #"{"requestAuthorization":"Basic dXNlcjpwYXNz"}"#,
        #"payload={\"proxyAuthorization\":\"Basic dXNlcjpwYXNz\"}"#,
        #"payload={\"requestAuthorization\":\"Basic dXNlcjpwYXNz\"}"#,
    ])
    func compoundAuthorizationJSONFieldsRemoveTheWholeValue(input: String) {
        let output = redactor.redact(input)
        #expect(!output.contains("dXNlcjpwYXNz"))
        #expect(output.contains("[redacted:authorization]"))
    }

    @Test(arguments: ["proxyAuthorization:", "payload.requestAuthorization="])
    func compoundAuthorizationFieldsRetainPendingValueContext(label: String) {
        let output = redactor.redact(lines: [label, "", "Basic dXNlcjpwYXNz", "Finished"]).map(\.text)
        #expect(output[0].contains("[redacted:authorization]"))
        #expect(output[1] == "")
        #expect(output[2] == "[redacted:authorization]")
        #expect(output[3] == "Finished")
    }

    @Test(arguments: [
        ("Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"),
        (#"Digest username="u", response="syntheticResponse""#, "syntheticResponse"),
    ])
    func decodingStandaloneAuthorizationValuesDoesNotRequireTheOriginalLabel(input: String, credential: String) throws {
        let encoded = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(RedactedLine.self, from: encoded)
        #expect(!decoded.text.contains(credential))
        #expect(decoded.text.contains("[redacted:authorization]"))
    }

    @Test(arguments: ["\u{8}", "\u{1B}[31m"], [12, 28])
    func decodingInterruptedBasicCredentialsDoesNotLeakARecognizablePrefix(control: String, offset: Int) throws {
        let credential = Data("synthetic-user:synthetic-password".utf8).base64EncodedString()
        let split = credential.index(credential.startIndex, offsetBy: offset)
        let input = "Basic " + credential[..<split] + control + credential[split...]
        let decoded = try JSONDecoder().decode(RedactedLine.self, from: JSONEncoder().encode(input))
        #expect(decoded.text == "Basic [redacted:authorization]")
    }

    @Test(arguments: ["Basic configuration loaded", "Digest calculation complete"])
    func decodingOrdinaryAuthorizationSchemeWordsPreservesDiagnostics(input: String) throws {
        let decoded = try JSONDecoder().decode(RedactedLine.self, from: JSONEncoder().encode(input))
        #expect(decoded.text == input)
    }

    @Test(arguments: [
        ("run --password --token secondSecret --json", ["--password"]),
        ("run --password --token=secondSecret --json", ["--password"]),
        ("run --password --token --api-key secondSecret --json", ["--password"]),
        ("run --password=firstSecret --token secondSecret --json", ["--password", "--token"]),
    ])
    func ambiguousCLIValuesDoNotHideTheNextCredentialValue(input: String, options: [String]) {
        let output = redactor.redact(input)
        #expect(!output.contains("firstSecret"))
        #expect(!output.contains("secondSecret"))
        #expect(output.contains("[redacted:secret]"))
        // Only unambiguous names must survive; a following option may itself be a password.
        #expect(options.allSatisfy { output.contains($0) })
        #expect(output.hasSuffix(" --json"))
    }

    @Test(arguments: ["-reviewOpaqueValue", "--reviewOpaqueValue", "'-reviewOpaqueValue'"])
    func dashLeadingOpaquePasswordsAreStillValues(value: String) {
        #expect(redactor.redact("run --password " + value + " --json")
            == "run --password [redacted:secret] --json")
    }

    @Test(arguments: [#"prefix"first"#, #""first"'second"#])
    func shellWordQuotesCanOpenAfterAnUnquotedOrQuotedSegment(value: String) {
        let closing = value.hasSuffix("second") ? "'" : "\""
        let output = redactor.redact(lines: ["run --password " + value, "third" + closing, "Finished"]).map(\.text)
        #expect(output == ["run --password [redacted:secret]", "[redacted:secret]", "Finished"])
    }

    @Test func closingQuotedValuesCanOpenPrivateKeyBlocks() {
        let output = redactor.redact(lines: [
            "password: \"first", "last\" -----BEGIN PRIVATE KEY-----", "reviewKeyMaterial",
            "-----END PRIVATE KEY-----", "Finished",
        ]).map(\.text)
        #expect(output[2] == "[redacted:private-key]")
        #expect(output[3] == "[redacted:private-key]")
        #expect(output[4] == "Finished")
    }

    @Test(arguments: [
        #"{"userCode":"reviewOpaqueCode"}"#,
        #"{"deviceCode":"reviewOpaqueCode"}"#,
        "payload.userCode=reviewOpaqueCode",
        #"payload={\"deviceCode\":\"reviewOpaqueCode\"}"#,
    ])
    func camelCaseDeviceCodeFieldsRemoveOpaqueValues(input: String) {
        let output = redactor.redact(input)
        #expect(!output.contains("reviewOpaqueCode"))
        #expect(output.contains("[redacted:device-code]"))
    }

    @Test(arguments: ["userCode:", "deviceCode=", #"{"deviceCode":"#])
    func camelCaseDeviceCodeFieldsRetainPendingValueContext(label: String) {
        let output = redactor.redact(lines: [label, "", "reviewOpaqueCode", "Finished"]).map(\.text)
        #expect(output[1] == "")
        #expect(output[2] == "[redacted:device-code]")
        #expect(output[3] == "Finished")
    }
}
