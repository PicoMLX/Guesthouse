import Foundation
import Testing
@testable import GuesthouseCore

/// All fixtures are synthetic. These cases exercise missing context and stream boundaries.
@Suite struct RedactorStreamingReviewTests {
    let redactor = Redactor()

    @Test(arguments: ["run --password", "run --password   ", "run --token=", "run --password --token", "run --client-credentials"], ["reviewOpaqueValue", " reviewOpaqueValue"])
    func bareOptionsCarryTheirValueAcrossLines(option: String, value: String) {
        let output = redactor.redact(lines: [option, "", "\u{1B}[0m", value, "Finished"]).map(\.text)
        #expect(output[1] == "")
        #expect(output[2] == "")
        #expect(output[3] == "[redacted:secret]")
        #expect(output[4] == "Finished")
    }

    @Test(arguments: ["credential", "credentials", "clientCredentials", "client_credentials"], [
        "{label}: alice:reviewOpaqueValue", #"{"{label}":"reviewOpaqueValue"}"#, "run --{label} reviewOpaqueValue --json",
    ])
    func credentialContainersShareTheSecretVocabulary(label: String, template: String) {
        let output = redactor.redact(template.replacing("{label}", with: label))
        #expect(!output.contains("reviewOpaqueValue"))
        #expect(output.contains("[redacted:secret]"))
    }

    @Test(arguments: ["credentials:", "clientCredentials=", #"{"credential":"#])
    func bareCredentialContainersKeepPendingContext(label: String) {
        let output = redactor.redact(lines: [label, "reviewOpaqueValue", "Finished"]).map(\.text)
        #expect(output[1] == "[redacted:secret]")
        #expect(output[2] == "Finished")
    }

    @Test(arguments: ["Your code is ABC123", "Your code is xy", "Your code is: lowercase", "Your code: opaqueValue"])
    func possessiveUnqualifiedCodeDeclarationsAreSensitive(input: String) {
        #expect(redactor.redact(input).contains("[redacted:device-code]"))
        #expect(redactor.redact(input) != input)
    }

    @Test(arguments: ["Your code is", "Your code is:", "Your code:"])
    func unqualifiedCodeDeclarationsCanWrap(prompt: String) {
        #expect(redactor.redact(lines: [prompt, "opaqueValue", "Finished"]).map(\.text).suffix(2)
            == ["[redacted:device-code]", "Finished"])
    }

    @Test(arguments: ["process exited with code 1", "Your code compiled successfully", "The login code was rejected"])
    func ordinaryCodeDiagnosticsRemainVisible(input: String) {
        #expect(redactor.redact(lines: [input, "Finished"]).map(\.text) == [input, "Finished"])
    }

    @Test(arguments: [
        "NTLM TlRMTVNTUABzeW50aGV0aWM=", "Negotiate c3ludGhldGljLWF1dGg=",
        "AWS4-HMAC-SHA256 Credential=syntheticIdentity, SignedHeaders=host, Signature=syntheticSignature",
    ], ["", "payload_"])
    func standaloneStandardizedAuthorizationValuesAreNotTrusted(input: String, prefix: String) throws {
        let decoded = try JSONDecoder().decode(RedactedLine.self, from: JSONEncoder().encode(prefix + input))
        #expect(decoded.text == prefix + "[redacted:authorization]")
    }

    @Test(arguments: ["payload_Bearer opaqueCredential", "payload_Basic dXNlcjpwYXNz", "payload_Digest username=\"u\", response=\"opaqueCredential\""])
    func underscoresSeparateStandaloneAuthorizationValues(input: String) {
        let output = redactor.redact(input)
        #expect(!output.contains("opaqueCredential"))
        #expect(!output.contains("dXNlcjpwYXNz"))
        #expect(output.hasPrefix("payload_"))
    }

    @Test(arguments: ["ghp_", "gho_", "github_pat_"], [0, 10, 28])
    func distinctiveGitHubPrefixesProtectWrappedPayloads(prefix: String, split: Int) {
        let payload = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let first = String(payload.prefix(split))
        let remainder = String(payload.dropFirst(split))
        let lines = ["artifact" + prefix + first, remainder + ".tmp", "Finished"]
        let expected = ["artifact[redacted:github-token]", "[redacted:github-token].tmp", "Finished"]
        #expect(redactor.redact(lines: lines).map(\.text) == expected)
        #expect(redactor.redact(lines.joined(separator: "\r\n")) == expected.joined(separator: "\r\n"))
    }

    @Test func wrappedTokensRetainTheirStateAcrossSeveralFragmentsAndBlankLines() {
        let output = redactor.redact(lines: ["ghp_ABCD", "", "\u{1B}[0m", "EFGHIJ", " KLMNOP.tmp", "Finished"]).map(\.text)
        #expect(output == ["[redacted:github-token]", "", "", "[redacted:github-token]", "[redacted:github-token].tmp", "Finished"])
    }

    @Test(arguments: ["HMAC-SHA256", "PBKDF2-HMAC-SHA256", "ECDSA-SHA256", "CHACHA20-POLY1305"])
    func knownAlgorithmsSurviveOnlyContextFreeShapeMatching(algorithm: String) throws {
        let input = "using " + algorithm + " for signing"
        #expect(redactor.redact(untrusted: input) == input)
        #expect(redactor.redact(fieldValue: input) == input)
        #expect(try JSONDecoder().decode(RedactedLine.self, from: JSONEncoder().encode(input)).text == input)
        #expect(!redactor.redact(untrusted: "device_code: " + algorithm).contains(algorithm))
        #expect(!redactor.redact(untrusted: "Your code is " + algorithm).contains(algorithm))
    }
}
