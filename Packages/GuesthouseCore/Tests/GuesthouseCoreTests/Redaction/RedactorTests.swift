import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactorTests {
    let redactor = Redactor()

    /// Synthetic secrets only. None of these values are real.
    static let secrets: [(kind: String, line: String, secret: String)] = [
        ("github classic", "remote: token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab used", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"),
        ("github oauth", "gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", "gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"),
        ("github fine-grained", "using github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ", "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ"),
        ("authorization header", "> Authorization: token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"),
        ("bearer", "curl -H 'Bearer abcdefghijklmnop.qrstuvwxyz'", "abcdefghijklmnop.qrstuvwxyz"),
        ("api key", "OPENAI_API_KEY is sk-proj-abcdefghijklmnopqrstuvwxyz0123", "sk-proj-abcdefghijklmnopqrstuvwxyz0123"),
        ("jwt", "session eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnopqrstuv", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnopqrstuv"),
        ("url userinfo", "cloning https://ronald:hunter2secret@github.com/PicoMLX/Guesthouse.git", "hunter2secret"),
        ("password label", "password: hunter2secret", "hunter2secret"),
        ("passphrase label", "Passphrase=\"correct horse battery\"", "correct horse battery"),
        ("token label", "token=abc123def456", "abc123def456"),
        ("github device code", "! First copy your one-time code: 1A2B-3C4D", "1A2B-3C4D"),
        ("codex device code", "Enter the code 9Z8Y-7X6W at the URL shown", "9Z8Y-7X6W"),
    ]

    @Test(arguments: secrets)
    func secretDoesNotSurvive(kind: String, line: String, secret: String) {
        let redacted = redactor.redact(line)
        #expect(!redacted.contains(secret), "\(kind): \(redacted)")
        #expect(redacted.contains("[redacted:"), "\(kind): no marker in \(redacted)")
    }

    @Test func markersNameTheKind() {
        #expect(redactor.redact("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab") == "[redacted:github-token]")
        #expect(redactor.redact("password: x") == "password: [redacted:secret]")
        #expect(redactor.redact("https://u:p@h/x") == "https://[redacted:userinfo]@h/x")
        #expect(redactor.redact("your code: AB12-CD34.") == "your code: [redacted:device-code].")
    }

    @Test func multiLinePEMBlockIsRemovedAcrossStreamedLines() {
        let lines = [
            "installing key",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW",
            "QyNTUxOQAAACBfakekeymaterialfakekeymaterialfakekeymaterialfakekeymat",
            "-----END OPENSSH PRIVATE KEY-----",
            "done",
        ]
        var state = Redactor.StreamState()
        let out = lines.map { redactor.redact(line: $0, state: &state).text }
        #expect(out[0] == "installing key")
        #expect(out[1] == "[redacted:private-key]")
        #expect(out[2] == "[redacted:private-key]")
        #expect(out[3] == "[redacted:private-key]")
        #expect(out[4] == "[redacted:private-key]")
        #expect(out[5] == "done")
        #expect(!out.joined().contains("fakekeymaterial"))
        #expect(state == Redactor.StreamState())
    }

    @Test func singleLinePEMIsRemovedInPlace() {
        let out = redactor.redact("key=-----BEGIN RSA PRIVATE KEY-----MIIEow-----END RSA PRIVATE KEY----- ok")
        #expect(out == "key=[redacted:private-key] ok")
    }

    @Test func wholeTextConvenienceHandlesPEM() {
        let text = "a\n-----BEGIN PRIVATE KEY-----\nSECRETMATERIAL\n-----END PRIVATE KEY-----\nb"
        let out = redactor.redact(text)
        #expect(!out.contains("SECRETMATERIAL"))
        #expect(out.hasPrefix("a\n"))
        #expect(out.hasSuffix("\nb"))
    }

    @Test func falsePositiveGuard() {
        let sha = "commit 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"
        let uuid = "environment 1A2B3C4D-0000-4000-8000-000000000000"
        let version = "Tart 2.36.0, Xcode 26.6 (17F113), protocol 1"
        let scopes = "Token scopes: 'admin:public_key', 'gist', 'read:org', 'repo'"
        let uuidOnCodeLine = "device code request for 1A2B3C4D-0000-4000-8000-000000000000 failed"
        let url = "cloning https://github.com/PicoMLX/Guesthouse.git"
        for line in [sha, uuid, version, scopes, uuidOnCodeLine, url] {
            #expect(redactor.redact(line) == line)
        }
    }

    @Test func redactedLineCanOnlyBeMadeFromLiteralsOrRedactor() throws {
        let literal = RedactedLine(literal: "Started")
        #expect(literal.text == "Started")
        let data = try JSONEncoder().encode(literal)
        #expect(String(decoding: data, as: UTF8.self) == "\"Started\"")
        #expect(try JSONDecoder().decode(RedactedLine.self, from: data) == literal)
    }

    @Test func fieldValuesRedactBareDeviceCodes() {
        #expect(redactor.redact(fieldValue: "AB12-CD34") == "[redacted:device-code]")
        #expect(redactor.redact(fieldValue: "0.50.0 (AB12-CD34)") == "0.50.0 ([redacted:device-code])")
        #expect(redactor.redact(fieldValue: "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab") == "[redacted:github-token]")
        #expect(redactor.redact(fieldValue: "2.36.0") == "2.36.0")
        #expect(redactor.redact(fieldValue: "1A2B3C4D-0000-4000-8000-000000000000") == "1A2B3C4D-0000-4000-8000-000000000000")
        #expect(redactor.redact("AB12-CD34") == "AB12-CD34", "log lines keep the context rule")
    }

    @Test func batchRedactionSharesStateAcrossLines() {
        let out = redactor.redact(lines: ["-----BEGIN X-----", "material", "-----END X-----", "password=x"])
        #expect(out.map(\.text) == [
            "[redacted:private-key]", "[redacted:private-key]", "[redacted:private-key]", "password: [redacted:secret]",
        ])
    }
}
