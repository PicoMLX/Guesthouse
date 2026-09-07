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
        #expect(redactor.redact(#"{"user_code":"AB12-CD34"}"#) == "{user_code: [redacted:device-code]}")
        #expect(redactor.redact("device_code=AB12-CD34") == "device_code: [redacted:device-code]")
    }

    @Test func codeFieldsOfAnyShapeAreRemoved() {
        #expect(redactor.redact(#"{"device_code":"a1b2c3d4e5f6g7h8"}"#) == "{device_code: [redacted:device-code]}")
        #expect(redactor.redact("user_code: WDJB.MJHT") == "user_code: [redacted:device-code]")
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

    @Test func anUnquotedLabeledSecretIsRemovedPastItsFirstWord() {
        #expect(redactor.redact("password: correct horse battery staple") == "password: [redacted:secret]")
        #expect(redactor.redact("passphrase = my ssh key phrase") == "passphrase: [redacted:secret]")
        #expect(redactor.redact(fieldValue: "token=a b c") == "token: [redacted:secret]")
        #expect(redactor.redact(#"{"token":"abc123","x":1}"#) == #"{token: [redacted:secret],"x":1}"#, "a quoted value still ends at its quote")
    }

    @Test func decodedRedactedLinesAreRedactedAgain() throws {
        let line = try JSONDecoder().decode(RedactedLine.self, from: Data(#""password: hunter2""#.utf8))
        #expect(line.text == "password: [redacted:secret]")
    }

    @Test func everyContinuationLineOfAFoldedHeaderIsRemoved() {
        let lines = [
            "Authorization: Digest username=\"u\",",
            "  realm=\"r\", nonce=\"n\",",
            "  response=\"abc123\"",
            "Accept: */*",
        ]
        let out = redactor.redact(lines: lines).map(\.text)
        #expect(out == [
            "Authorization: [redacted:authorization]",
            "[redacted:authorization]",
            "[redacted:authorization]",
            "Accept: */*",
        ])
    }

    @Test func aPEMBlockOpenedByAContinuationLineKeepsRedacting() {
        let lines = [
            "\"Authorization\":",
            "  -----BEGIN PRIVATE KEY-----",
            "MIIEfakekeymaterial",
            "-----END PRIVATE KEY-----",
            "after",
        ]
        let out = redactor.redact(lines: lines).map(\.text)
        #expect(!out.joined().contains("fakekeymaterial"))
        #expect(out[2] == "[redacted:private-key]")
        #expect(out[3] == "[redacted:private-key]")
        #expect(out.last == "after")
    }

    @Test func crlfTextIsSplitIntoLines() {
        let text = "Authorization: Digest username=\"u\",\r\n  nonce=\"n\", response=\"abc123\"\r\nAccept: */*"
        let out = redactor.redact(text)
        #expect(!out.contains("abc123"))
        #expect(out == "Authorization: [redacted:authorization]\r\n[redacted:authorization]\r\nAccept: */*")
    }

    @Test func aBareSecretLabelRedactsTheValueOnTheNextLine() {
        #expect(redactor.redact("password:\ncorrect horse battery") == "password: [redacted:secret]\n[redacted:secret]")
        let json = redactor.redact("{\n  \"token\":\n    \"opaqueCredential\"\n}")
        #expect(!json.contains("opaqueCredential"))
        #expect(redactor.redact("token=abc123\nnext line") == "token: [redacted:secret]\nnext line")
    }

    @Test func aControlStringSpanningLinesKeepsItsPayloadSuppressed() {
        let out = redactor.redact(lines: ["\u{1B}]0;my", "title\u{1B}\\\(token)"]).map(\.text)
        #expect(!out.joined().contains(token))
        #expect(out == ["", "[redacted:github-token]"])
    }

    @Test func escapesWithIntermediateBytesAreStripped() {
        #expect(redactor.redact("\u{1B}(B\(token)") == "[redacted:github-token]")
    }

    @Test func escapedAndSingleQuotedAuthorizationKeysAreRecognized() {
        #expect(!redactor.redact(#"payload={\"Authorization\":\"Basic dXNlcjpwYXNz\"}"#).contains("dXNlcjpwYXNz"))
        #expect(redactor.redact("{'Authorization': 'Basic dXNlcjpwYXNz'}") == "{Authorization: [redacted:authorization]}")
    }

    @Test func tokensNextToADotOrASlashAreRemoved() {
        #expect(redactor.redact("\(token).partial") == "[redacted:github-token].partial")
        #expect(redactor.redact("/var/folders/T/\(token)/id_rsa") == "/var/folders/T/[redacted:github-token]/id_rsa")
        #expect(redactor.redact("wrote \(token)") == "wrote [redacted:github-token]")
        #expect(redactor.redact("cache/\(token).partial.tmp") == "cache/[redacted:github-token].partial.tmp")
        let key = "sk-proj-abcdefghijklmnopqrstuvwxyz"
        #expect(redactor.redact("\(key).partial") == "[redacted:api-key].partial")
        #expect(redactor.redact("/tmp/\(key)") == "/tmp/[redacted:api-key]")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnopqrstuv"
        #expect(redactor.redact("session.\(jwt)") == "session.[redacted:jwt]")
        #expect(redactor.redact("\(jwt).partial") == "[redacted:jwt].partial")
        // The dot in an identifier still has to survive the stricter anchors.
        for plain in ["com.apple.dt.Xcode", "docs.example.com", "Tart 2.36.0", "note.txt"] {
            #expect(redactor.redact(plain) == plain)
        }
    }

    @Test func labelsNextToADotOrASlashAreRecognized() {
        #expect(redactor.redact("payload.Authorization: Basic dXNlcjpwYXNz") == "payload.Authorization: [redacted:authorization]")
        #expect(redactor.redact("req.password: hunter2") == "req.password: [redacted:secret]")
        #expect(redactor.redact("wrote /tmp/cache/password: hunter2") == "wrote /tmp/cache/password: [redacted:secret]")
        #expect(redactor.redact("Authorization: Basic dXNlcjpwYXNz") == "Authorization: [redacted:authorization]")
        #expect(redactor.redact("cfg.device_code=a1b2c3d4e5") == "cfg.device_code: [redacted:device-code]")
        #expect(redactor.redact("req.password:\ncorrect horse battery") == "req.password: [redacted:secret]\n[redacted:secret]")
        // The anchor is still `\b` for word characters: a label has to begin a word.
        #expect(redactor.redact("released 12 tokens: 42") == "released 12 tokens: 42")
        #expect(redactor.redact("mypassword: hunter2") == "mypassword: hunter2")
    }

    @Test func labelsAfterAnUnderscoreAreRecognized() {
        #expect(redactor.redact("refresh_token=abc123") == "refresh_token: [redacted:secret]")
        #expect(redactor.redact("access_token: abc123") == "access_token: [redacted:secret]")
        #expect(!redactor.redact(#"{"refresh_token":"abc123"}"#).contains("abc123"))
        #expect(redactor.redact("x_authorization: Basic dXNlcjpwYXNz") == "x_Authorization: [redacted:authorization]")
        // An ordinary word that ends in a label is still not a label, and a name that only
        // mentions one, with no value after it, is left for the token rules.
        #expect(redactor.redact("mypassword: hunter2") == "mypassword: hunter2")
        #expect(redactor.redact("OPENAI_API_KEY is sk-proj-abcdefghijklmnopqrstuvwxyz0123") == "OPENAI_API_KEY is [redacted:api-key]")
    }

    @Test func decodingRemovesBareDeviceCodes() throws {
        let line = try JSONDecoder().decode(RedactedLine.self, from: Data(#""AB12-CD34""#.utf8))
        #expect(line.text == "[redacted:device-code]")
    }

    @Test func escapedAndSingleQuotedSecretLabelsAreRecognized() {
        #expect(redactor.redact("{'password':'hunter2'}") == "{password: [redacted:secret]}")
        #expect(!redactor.redact(#"payload={\"token\":\"abc123\"}"#).contains("abc123"))
    }

    @Test func anUnquotedLabeledValueIsRemovedToTheEndOfTheLine() {
        #expect(redactor.redact("password: correct horse battery") == "password: [redacted:secret]")
        #expect(redactor.redact("passphrase = a b c") == "passphrase: [redacted:secret]")
        let opaque = "device_code: metadata 3584d83530557fdd1f46af8289938c8ef79f9dc5"
        #expect(redactor.redact(opaque) == "device_code: [redacted:device-code]")
    }

    @Test func escapedSlashesInACredentialURLAreRecognized() {
        let escaped = #"cloning https:\/\/user:hunter2@example.com\/repo.git"#
        #expect(!redactor.redact(escaped).contains("hunter2"))
        #expect(redactor.redact(escaped).contains("[redacted:userinfo]"))
    }

    @Test func anExpectedDeviceCodeOfAnyShapeIsRemoved() {
        let out = redactor.redact(lines: ["Your one-time code is:", "WDJB.MJHT"]).map(\.text)
        #expect(out == ["Your one-time code is:", "[redacted:device-code]"])
    }

    @Test func aConsumedSecretValueStillArmsTheNextPrompt() {
        let out = redactor.redact(lines: ["password:", "Your one-time code is:", "AB12-CD34"]).map(\.text)
        #expect(out == ["password: [redacted:secret]", "[redacted:secret]", "[redacted:device-code]"])
    }

    @Test func everyJWTInADottedRunIsRemoved() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnopqrstuv"
        #expect(redactor.redact("t \(jwt).\(jwt)") == "t [redacted:jwt].[redacted:jwt]")
    }

    @Test func authorizationContextSurvivesBlankLines() {
        let out = redactor.redact(lines: ["Authorization:", "\u{1B}[0m", " Basic dXNlcjpwYXNz"]).map(\.text)
        #expect(out == ["Authorization: [redacted:authorization]", "", "[redacted:authorization]"])
    }

    /// Folding is an HTTP wire rule; a CLI or a pretty-printer puts the value of a bare label on
    /// the next line without indenting it, and no rule recognizes a bare `Basic …`.
    @Test func anUnindentedAuthorizationValueIsStillTheValue() {
        let out = redactor.redact(lines: ["Authorization:", "Basic dXNlcjpwYXNz"]).map(\.text)
        #expect(out == ["Authorization: [redacted:authorization]", "[redacted:authorization]"])
        let digest = redactor.redact(lines: ["Authorization:", "Digest username=\"u\", response=\"abc\""]).map(\.text)
        #expect(digest.last == "[redacted:authorization]")
        // A line that names no scheme is the next header, not the value.
        let headers = redactor.redact(lines: ["Authorization:", "Accept: */*"]).map(\.text)
        #expect(headers == ["Authorization: [redacted:authorization]", "Accept: */*"])
    }

    /// The prose an RFC 8628 provider prints has no delimiter at all, and only a value with the
    /// hyphenated or dotted shape was being removed from it.
    @Test func aPromptWithNoDelimiterStillLosesItsCode() {
        #expect(redactor.redact("Enter the code ABC123 at the URL shown") == "Enter the code [redacted:device-code] at the URL shown")
        #expect(redactor.redact("Enter the code 9Z8Y-7X6W at the URL shown") == "Enter the code [redacted:device-code] at the URL shown")
        #expect(redactor.redact("copy the code a1b2c3d4 into the browser") == "copy the code [redacted:device-code] into the browser")
        // A mention is not a prompt, and the word after a prompt is not always a code.
        #expect(redactor.redact("process exited with code 1") == "process exited with code 1")
        #expect(redactor.redact("Enter the code shown below") == "Enter the code shown below")
    }

    /// The device-code rule says it leaves longer dotted identifiers alone, and a dot that
    /// continues one is as much a part of it as a hyphen is.
    @Test func aDottedIdentifierKeepsItsCodeShapedPrefix() {
        #expect(redactor.redact(fieldValue: "ABCD-EFGH.example.com") == "ABCD-EFGH.example.com")
        #expect(redactor.redact(fieldValue: "AB12-CD34.") == "[redacted:device-code].", "a dot that ends a sentence is not one")
    }

    /// A query or a fragment ends an authority exactly as a path does, so an `@` in one is not
    /// userinfo and a legitimate provider link keeps its shape.
    @Test func aQueryOrFragmentEndsTheAuthority() {
        #expect(redactor.redact("https://example.com?email=user@example.org") == "https://example.com?email=user@example.org")
        #expect(redactor.redact("https://example.com#user@example.org") == "https://example.com#user@example.org")
        #expect(redactor.redact("https://user:secret@example.com?to=a@b") == "https://[redacted:userinfo]@example.com?to=a@b")
    }

    @Test func tokensAfterAnUnderscoreAreRemoved() {
        #expect(redactor.redact("artifact_\(token).txt") == "artifact_[redacted:github-token].txt")
        #expect(redactor.redact(fieldValue: "cache_sk-proj-abcdefghijklmnopqrstuvwxyz") == "cache_[redacted:api-key]")
    }

    @Test func stylingInFrontOfATokenDoesNotHideWhereItStarts() {
        // The boundary the styling stood on is only a reading: what is emitted is the line with
        // the styling closed up, and the token removed from it.
        #expect(redactor.redact("prefix\u{1B}[31m\(token)\u{1B}[0m") == "prefix[redacted:github-token]")
        let key = "sk-proj-abcdefghijklmnopqrstuvwxyz"
        #expect(redactor.redact("x\u{9B}1m\(key)") == "x[redacted:api-key]")
        // Styling inside a label still closes up, or the label would stop being one.
        #expect(redactor.redact("pass\u{1B}[0mword: hunter2") == "password: [redacted:secret]")
        // One line can do both, and then each reading finds only one of the two secrets. What
        // each removes is kept, rather than the readings being compared by how much they found.
        #expect(redactor.redact("prefix\u{1B}[31m\(token) x pass\u{1B}[0mword: hunter2")
            == "prefix[redacted:github-token] x password: [redacted:secret]")
    }

    @Test func aSecretPromptInsideAFoldedHeaderArmsTheNextLine() {
        let out = redactor.redact(lines: ["Authorization: Digest realm=\"r\",", "  password:", "hunter2"]).map(\.text)
        #expect(out == ["Authorization: [redacted:authorization]", "[redacted:authorization]", "[redacted:secret]"])
    }

    @Test func aLabeledValueFoldedOntoTheNextLineIsRemovedInFull() {
        let out = redactor.redact(lines: ["passphrase: correct horse", "  battery staple", "done"]).map(\.text)
        #expect(out == ["passphrase: [redacted:secret]", "[redacted:secret]", "done"])
        #expect(redactor.redact("token=abc123\nnext line") == "token: [redacted:secret]\nnext line")
    }

    @Test func camelCaseCredentialKeysAreRecognized() {
        #expect(redactor.redact(#"{"accessToken":"opaqueCredential"}"#) == "{accessToken: [redacted:secret]}")
        #expect(redactor.redact("refreshToken=abc123") == "refreshToken: [redacted:secret]")
        #expect(redactor.redact("clientSecret: abc123") == "clientSecret: [redacted:secret]")
        // A word that merely ends in a label word is still not one.
        #expect(redactor.redact("nonToken: 42") == "nonToken: 42")
        #expect(redactor.redact("mypassword: hunter2") == "mypassword: hunter2")
    }

    @Test func aCodePromptRemovesTheValueOnItsOwnLine() {
        #expect(redactor.redact("Your one-time code is: WDJB.MJHT") == "Your one-time code is: [redacted:device-code]")
        #expect(redactor.redact("verification code = 7788ZZ") == "verification code = [redacted:device-code]")
        #expect(redactor.redact("user code: WDJB.MJHT") == "user code: [redacted:device-code]")
    }

    /// A prompt's value is as opaque as a `user_code` field's, so the tail a forced cut leaves
    /// in the next record matches nothing on its own shape: the prompt has to go on removing
    /// it the way the field rule does.
    @Test func aCodePromptValueIsRemovedThroughAForcedCut() {
        var state = Redactor.StreamState()
        let first = redactor.redact(line: "verification code: opaque-value", continuesPreviousRecord: false, state: &state)
        let second = redactor.redact(line: ",rest-of-the-value", continuesPreviousRecord: true, state: &state)
        #expect(first.text == "verification code: [redacted:device-code]")
        #expect(second.text == "[redacted:device-code]", "the rest of the code left the redaction layer verbatim")
    }

    @Test func anOrdinaryMentionOfACodeDoesNotArmTheNextLine() {
        let out = redactor.redact(lines: ["process exited with code 1", "tart: could not find the VM"]).map(\.text)
        #expect(out == ["process exited with code 1", "tart: could not find the VM"])
    }

    @Test func aJWTGluedToAFileNameIsRemoved() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnopqrstuv"
        #expect(redactor.redact("artifact_\(jwt)") == "artifact_[redacted:jwt]")
        #expect(redactor.redact("artifact-\(jwt).tmp") == "artifact-[redacted:jwt].tmp")
    }

    @Test func decodingRemovesCodesOfOtherShapes() throws {
        let line = try JSONDecoder().decode(RedactedLine.self, from: Data(#""WDJB.MJHT""#.utf8))
        #expect(line.text == "[redacted:device-code]")
        #expect(redactor.redact(fieldValue: "1A2B3C4D-0000-4000-8000-000000000000") == "1A2B3C4D-0000-4000-8000-000000000000")
        #expect(redactor.redact(fieldValue: "com.apple.dt.Xcode") == "com.apple.dt.Xcode")
    }

    @Test func aBELDoesNotTerminateANonOSCControlString() {
        #expect(redactor.redact("\u{1B}Pabc\u{07}x\(token)\u{1B}\\") == "")
        let out = redactor.redact(lines: ["\u{1B}Pabc", "\u{07}x\(token)\u{1B}\\"]).map(\.text)
        #expect(out == ["", ""])
    }

    @Test func anUnlistedAuthorizationSchemeIsStillTheValue() {
        // RFC 7235 keeps an open registry, so what makes the next line the value is that it is
        // not itself a header, not that it names a scheme this file happens to know.
        var state = Redactor.StreamState()
        _ = redactor.redact(line: "Authorization:", state: &state)
        #expect(redactor.redact(line: "Custom opaqueCredential", state: &state).text == "[redacted:authorization]")
        var next = Redactor.StreamState()
        _ = redactor.redact(line: "Authorization:", state: &next)
        #expect(redactor.redact(line: "Accept: */*", state: &next).text == "Accept: */*")
    }

    @Test func aBareAuthorizationLabelMayUseEquals() {
        let out = redactor.redact(lines: ["Authorization=", "Basic dXNlcjpwYXNz"]).map(\.text)
        #expect(out == ["Authorization: [redacted:authorization]", "[redacted:authorization]"])
    }

    @Test func aTokenConcatenatedOntoAWordIsRemoved() {
        #expect(redactor.redact("artifact\(token)") == "artifact[redacted:github-token]")
        #expect(redactor.redact("artifact_\(token)") == "artifact_[redacted:github-token]")
        // The API-key rule keeps its boundary, or ordinary hyphenated English would go with it.
        #expect(redactor.redact("risk-averse-approach-taken") == "risk-averse-approach-taken")
    }

    @Test func aDeclarativeCodePromptLosesItsValue() {
        #expect(redactor.redact("Your one-time code is ABC123") == "Your one-time code is [redacted:device-code]")
        #expect(redactor.redact("The verification code is 7788ZZ, valid for 15 minutes") == "The verification code is [redacted:device-code], valid for 15 minutes")
        #expect(redactor.redact("The login code was rejected") == "The login code was rejected")
    }

    @Test func aPrivateKeyLabelMayCarryHyphens() {
        let block = "-----BEGIN ACME-PRIVATE KEY-----\nsecretmaterial\n-----END ACME-PRIVATE KEY-----"
        #expect(redactor.redact(block) == "[redacted:private-key]\n[redacted:private-key]\n[redacted:private-key]")
        #expect(redactor.redact("-----BEGIN X9.42 DH PARAMETERS-----AAA-----END X9.42 DH PARAMETERS-----") == "[redacted:private-key]")
    }

    @Test func aSecretPassedAsACommandOptionIsRemoved() {
        #expect(redactor.redact("codex login --password hunter2 --verbose") == "codex login --password [redacted:secret] --verbose")
        #expect(redactor.redact("gh auth --github-token opaqueCredential") == "gh auth --github-token [redacted:secret]")
        #expect(redactor.redact(#"run --password "correct horse" --json"#) == "run --password [redacted:secret] --json")
    }
}
