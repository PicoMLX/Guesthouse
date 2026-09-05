import Foundation
import Testing
@testable import GuesthouseCore

/// All values are synthetic. Each stream owns its state, so cases can run in parallel.
@Suite struct RedactorInteractionTests {
    let redactor = Redactor()

    @Test(arguments: [
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789",
    ], [
        ("password: interactionPasswordValue", "interactionPasswordValue", "secret"),
        ("token: interactionTokenValue", "interactionTokenValue", "secret"),
        ("Authorization: Custom interactionAuthValue", "interactionAuthValue", "authorization"),
        ("device_code: interactionCodeValue", "interactionCodeValue", "device-code"),
        ("Your code is interactionPromptValue", "interactionPromptValue", "device-code"),
        ("run --password interactionCLIValue --json", "interactionCLIValue", "secret"),
        ("-----BEGIN PRIVATE KEY-----interactionKeyValue-----END PRIVATE KEY-----", "interactionKeyValue", "private-key"),
        (#"argv=["run", "--password", "interactionArgvValue", "--json"]"#, "interactionArgvValue", "secret"),
    ])
    func tokenContinuationsCannotHideSubsequentCredentialLabels(token: String, field: (String, String, String)) {
        let output = redactor.redact(lines: [token, field.0, "[status] operation completed."]).map(\.text)
        #expect(!output[0].contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!output[1].contains(field.1))
        #expect(output[1].contains("[redacted:" + field.2 + "]"))
        #expect(output[2] == "[status] operation completed.")
    }

    @Test(arguments: [
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789",
    ], [
        ("password:", "interactionPendingValue", "", "secret"),
        ("token=", "interactionPendingValue", "", "secret"),
        ("Authorization:", "Custom interactionPendingValue", "", "authorization"),
        ("device_code:", "interactionPendingValue", "", "device-code"),
        ("Your code is:", "interactionPendingValue", "", "device-code"),
        ("run --password", "interactionPendingValue", "", "secret"),
        ("-----BEGIN PRIVATE KEY-----", "interactionPendingValue", "-----END PRIVATE KEY-----", "private-key"),
        (#"argv=["run", "--password","#, #""interactionPendingValue"]"#, "", "secret"),
    ])
    func tokenContinuationsRetainContextsForTheFollowingValue(token: String, field: (String, String, String, String)) {
        let lines = [token, field.0, "", "\u{1B}[0m", field.1, field.2, "[status] operation completed."]
        let output = redactor.redact(lines: lines).map(\.text)
        #expect(!output[4].contains("interactionPendingValue"))
        #expect(output[4].contains("[redacted:" + field.3 + "]"))
        #expect(output[6] == "[status] operation completed.")
        #expect(redactor.redact(lines.joined(separator: "\n")) == output.joined(separator: "\n"))
    }

    @Test(arguments: ["sk-proj-", "sk-svcacct-", "sk-ant-api03-"], [
        ("", "abcdefgh", ""),
        ("abcd", "efgh", "\u{8}"),
        ("abcdefghijklmnopqrstuvwxyz01", "23456789abcd", ""),
        ("abcdefghijklmnopqrstuvwxyz01", "23456789abcd", "\u{1B}[31m"),
    ])
    func distinctiveAPIKeysProtectShortAndLongWrappedPayloads(prefix: String, fragments: (String, String, String)) {
        let first = fragments.0.prefix(2) + fragments.2 + fragments.0.dropFirst(2)
        let second = fragments.1.prefix(2) + fragments.2 + fragments.1.dropFirst(2)
        let lines = ["artifact" + prefix + first, "", "\u{1B}[0m", second + ".tmp", "[status] operation completed."]
        let expected = ["artifact[redacted:api-key]", "", "", "[redacted:api-key].tmp", "[status] operation completed."]
        #expect(redactor.redact(lines: lines).map(\.text) == expected)
        #expect(redactor.redact(lines.joined(separator: "\r\n")) == expected.joined(separator: "\r\n"))
    }

    @Test(arguments: ["--password", "--token"], [
        (" \\", "interactionShellValue"),
        ("=\\", "interactionShellValue"),
        (" firstSegment\\", "interactionShellValue"),
    ])
    func shellLineContinuationsProtectTheValueOnTheNextLine(option: String, value: (String, String)) {
        let lines = ["run " + option + value.0, value.1, "[status] operation completed."]
        let output = redactor.redact(lines: lines).map(\.text)
        #expect(output[0].contains(option))
        #expect(!output[0].contains("firstSegment"))
        #expect(!output[1].contains("interactionShellValue"))
        #expect(output[1].contains("[redacted:secret]"))
        #expect(output[2] == "[status] operation completed.")
        #expect(redactor.redact(lines.joined(separator: "\n")) == output.joined(separator: "\n"))
    }

    @Test(arguments: ["--password", "--token"], [
        #"argv=["run", "{option}", "interactionArgvValue", "--json"]"#,
        #"argv=['run', '{option}', 'interactionArgvValue', '--json']"#,
        #"payload=\"argv=[\"run\", \"{option}\", \"interactionArgvValue\", \"--json\"]\""#,
        #"argv=["run","{option}","interactionArgvValue","--json"]"#,
    ])
    func serializedArgumentsProtectTheElementFollowingASecretOption(option: String, template: String) {
        let input = template.replacingOccurrences(of: "{option}", with: option)
        let output = redactor.redact(input)
        #expect(!output.contains("interactionArgvValue"))
        #expect(output.contains("[redacted:secret]"))
        #expect(output.contains(option))
        #expect(output.contains("--json"))
    }

    @Test(arguments: ["--password", "--token"], [
        (#"argv=["run", "{option}","#, #""interactionArgvValue", "--json"]"#),
        (#"argv=['run', '{option}',"#, #"'interactionArgvValue', '--json']"#),
        (#"payload=\"argv=[\"run\", \"{option}\","#, #"\"interactionArgvValue\", \"--json\"]\""#),
    ])
    func serializedArgumentsKeepPendingValuesAcrossLineBreaks(option: String, template: (String, String)) {
        let lines = [template.0.replacingOccurrences(of: "{option}", with: option), "", template.1, "[status] operation completed."]
        let output = redactor.redact(lines: lines).map(\.text)
        #expect(output[0].contains(option))
        #expect(output[1] == "")
        #expect(!output[2].contains("interactionArgvValue"))
        #expect(output[2].contains("[redacted:secret]"))
        #expect(output[3] == "[status] operation completed.")
        #expect(redactor.redact(lines.joined(separator: "\r\n")) == output.joined(separator: "\r\n"))
    }

    @Test(arguments: [
        #"argv=["run", "--output", "report.json", "--json"]"#,
        #"argv=['run', '--format', 'plain', '--verbose']"#,
        #"payload=\"argv=[\"run\", \"--output\", \"report.json\"]\""#,
    ])
    func serializedOrdinaryOptionsPreserveDiagnostics(input: String) {
        #expect(redactor.redact(input) == input)
    }
}
