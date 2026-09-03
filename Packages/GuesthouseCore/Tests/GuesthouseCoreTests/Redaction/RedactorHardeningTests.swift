import Foundation
import Testing
@testable import GuesthouseCore

/// Cases from review: multi-parameter headers, JSON keys, several PEM blocks per line,
/// underscored code fields, context carried across lines, JOSE headers with whitespace, and
/// C1/OSC control sequences. All secrets are synthetic.
@Suite struct RedactorHardeningTests {
    let redactor = Redactor()
    let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"

    @Test func wholeAuthorizationValueIsRemoved() {
        let digest = "Authorization: Digest username=\"u\", realm=\"r\", nonce=\"n\", response=\"abc123\""
        #expect(redactor.redact(digest) == "Authorization: [redacted:authorization]")
        let sigv4 = "authorization: AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20260903/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=deadbeef"
        #expect(redactor.redact(sigv4) == "Authorization: [redacted:authorization]")
        #expect(redactor.redact(#"{"Authorization":"Basic dXNlcjpwYXNz","x":1}"#) == #"{Authorization: [redacted:authorization],"x":1}"#)
        #expect(redactor.redact(#"{"token":"abc123"}"#) == #"{token: [redacted:secret]}"#)
    }

    @Test func foldedContinuationOfAnyLengthIsRemoved() {
        var state = Redactor.StreamState()
        _ = redactor.redact(line: "\"Authorization\":", state: &state)
        let continuation = "  Digest username=\"u\", realm=\"r\", nonce=\"n\", response=\"abc123\""
        #expect(redactor.redact(line: continuation, state: &state).text == "[redacted:authorization]")
    }

    @Test func shortBearerTokensAreRemoved() {
        #expect(redactor.redact("Bearer abc123") == "Bearer [redacted:bearer-token]")
    }

    @Test func everyPEMBlockOnALineIsRemoved() {
        let line = #"{"a":"-----BEGIN PRIVATE KEY-----AAA-----END PRIVATE KEY-----","b":"-----BEGIN RSA PRIVATE KEY-----BBB-----END RSA PRIVATE KEY-----"}"#
        #expect(redactor.redact(line) == #"{"a":"[redacted:private-key]","b":"[redacted:private-key]"}"#)
    }

    @Test func pemStateEndsOnlyAtTheMatchingFooter() {
        let lines = ["-----BEGIN PRIVATE KEY-----", "AAA", "-----END CERTIFICATE-----", "BBB", "-----END PRIVATE KEY-----", "after"]
        let expected = Array(repeating: "[redacted:private-key]", count: 5) + ["after"]
        #expect(redactor.redact(lines: lines).map(\.text) == expected)
    }

    @Test func underscoredCodeFieldsAreRecognized() {
        #expect(redactor.redact(#"{"user_code":"AB12-CD34"}"#) == #"{"user_code":"[redacted:device-code]"}"#)
        #expect(redactor.redact("device_code=AB12-CD34") == "device_code=[redacted:device-code]")
    }

    @Test func deviceCodeContextCarriesToTheNextLine() {
        let out = redactor.redact(lines: ["Your one-time code is:", "AB12-CD34", "AB12-CD34"]).map(\.text)
        #expect(out == ["Your one-time code is:", "[redacted:device-code]", "AB12-CD34"])
    }

    @Test func joseHeadersWithWhitespaceAreRecognized() {
        func base64url(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
        }
        for header in [" {\"alg\":\"none\"}", "{\n \"alg\": \"none\"\n}", "\t{\"alg\":\"HS256\"}"] {
            let jwt = "\(base64url(header)).e30.sig"
            #expect(redactor.redact("t \(jwt)") == "t [redacted:jwt]", "\(jwt)")
        }
        for plain in ["docs.example.com", "com.apple.dt.Xcode", "tart 2.36.0"] {
            #expect(redactor.redact(plain) == plain)
        }
    }

    @Test func c1AndControlStringSequencesAreStripped() {
        #expect(redactor.redact("\u{9B}31m\(token)\u{9B}0m") == "[redacted:github-token]")
        #expect(redactor.redact("\u{1B}]8;;https://example.com\u{1B}\\\(token)\u{1B}]8;;\u{1B}\\") == "[redacted:github-token]")
        #expect(redactor.redact("\u{1B}]0;title\u{07}\(token)") == "[redacted:github-token]")
        #expect(Redactor.stripTerminalEscapes("\u{1B}[1mbold\u{1B}[0m \u{1B}Pdcs\u{1B}\\x") == "bold x")
    }

    @Test func continuationAfterAPartialAuthorizationValueIsRemoved() {
        let out = redactor.redact(lines: ["Authorization: Digest username=\"u\",", "  nonce=\"n\", response=\"abc123\"", "Accept: */*"]).map(\.text)
        #expect(out == ["Authorization: [redacted:authorization]", "[redacted:authorization]", "Accept: */*"])
    }

    @Test func aFooterLineThatOpensAnotherBlockKeepsRedacting() {
        let lines = ["-----BEGIN PRIVATE KEY-----", "AAA", "-----END PRIVATE KEY----- -----BEGIN RSA PRIVATE KEY-----", "BBB", "-----END RSA PRIVATE KEY-----", "after"]
        let out = redactor.redact(lines: lines).map(\.text)
        #expect(out.dropLast().allSatisfy { !$0.contains("AAA") && !$0.contains("BBB") })
        #expect(out[2] == "[redacted:private-key] [redacted:private-key]")
        #expect(out[3] == "[redacted:private-key]")
        #expect(out.last == "after")
    }

    @Test func deviceCodeContextSurvivesBlankLines() {
        let out = redactor.redact(lines: ["Your one-time code is:", "", "\u{1B}[0m", "AB12-CD34", "AB12-CD34"]).map(\.text)
        #expect(out == ["Your one-time code is:", "", "", "[redacted:device-code]", "AB12-CD34"])
    }

    @Test func decodedRedactedLinesAreRedactedAgain() throws {
        let line = try JSONDecoder().decode(RedactedLine.self, from: Data(#""password: hunter2""#.utf8))
        #expect(line.text == "password: [redacted:secret]")
    }
}
