import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RedactorPPKTests {
    private static let marker = "[redacted:private-key]"
    // Deliberately synthetic framing: these blobs are not private keys or cryptographic MACs.
    private static func key(version: Int = 3, encryption: String = "none") -> [String] {
        var lines = ["PuTTY-User-Key-File-\(version): ssh-ed25519", "Encryption: \(encryption)",
                     "Comment: synthetic fixture", "Public-Lines: 1", "cHVibGlj"]
        if version == 3, encryption != "none" {
            lines += ["Key-Derivation: Argon2id", "Argon2-Memory: 8", "Argon2-Passes: 1",
                      "Argon2-Parallelism: 1", "Argon2-Salt: 0123456789abcdef"]
        }
        return lines + ["Private-Lines: 2", "AAAA", "BBBB",
                        "Private-MAC: " + String(repeating: "a", count: version == 2 ? 40 : 64)]
    }

    @Test(arguments: [2, 3], ["none", "aes256-cbc"])
    func helperConsumesCompleteFilesAndResumes(version: Int, encryption: String) {
        var phase = Redactor.StreamState.PPKPhase.inactive
        #expect(!Redactor.consumePPKLine("before", phase: &phase))
        for line in Self.key(version: version, encryption: encryption) {
            #expect(Redactor.consumePPKLine(line, phase: &phase))
        }
        #expect(phase == .inactive)
        #expect(!Redactor.consumePPKLine("after", phase: &phase))
    }

    @Test(arguments: [2, 3], ["none", "aes256-cbc"])
    func publicRoutesHideEveryLine(version: Int, encryption: String) throws {
        let lines = Self.key(version: version, encryption: encryption)
        let input = (lines + ["after"]).joined(separator: "\n")
        let expected = (Array(repeating: Self.marker, count: lines.count) + ["after"]).joined(separator: "\n")
        let redactor = Redactor()
        #expect(redactor.redact(input) == expected)
        #expect(redactor.redact(untrusted: input) == expected)
        #expect(redactor.redact(fieldValue: input) == expected)
        #expect(redactor.redact(lines: lines + ["after"]).map(\.text).joined(separator: "\n") == expected)
        #expect(try JSONDecoder().decode(RedactedLine.self, from: JSONEncoder().encode(input)).text == expected)
        #expect(redactor.redact(expected) == expected)
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func physicalLineTerminatorsAndBackToBackKeysArePreserved(separator: String) {
        let lines = Self.key(version: 2) + Self.key() + ["after"]
        let expected = Array(repeating: Self.marker, count: lines.count - 1) + ["after"]
        #expect(Redactor().redact(lines.joined(separator: separator)) == expected.joined(separator: separator))
    }

    @Test(arguments: ["0", "-1", "+1", "1x", "", String(repeating: "9", count: 100)])
    func malformedCountsStayClosedUntilTheStreamIsReset(count: String) {
        var phase = Redactor.StreamState.PPKPhase.inactive
        let lines = ["PuTTY-User-Key-File-3: ssh-rsa", "Private-Lines: " + count]
            + Array(Self.key().dropFirst()) + ["after"]
        for line in lines { #expect(Redactor.consumePPKLine(line, phase: &phase)) }
        #expect(phase == .invalid)
        phase = .inactive
        #expect(!Redactor.consumePPKLine("after reset", phase: &phase))
    }

    @Test(arguments: [(1, ["AAAA", "BBBB"]), (3, ["AAAA", "BBBB"]),
                      (2, ["AA!A", "BBBB"]), (2, ["QQ==", "BBBB"])])
    func countsCannotReleaseShortLongOrMalformedBodies(count: Int, body: [String]) {
        let lines = ["PuTTY-User-Key-File-3: ssh-rsa", "Private-Lines: \(count)"] + body
            + ["Private-MAC: " + String(repeating: "a", count: 64), "after"]
        #expect(Redactor().redact(lines: lines).allSatisfy { $0.text == Self.marker })
    }

    @Test(arguments: ["", "not-hex", String(repeating: "a", count: 40),
                      String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                      String(repeating: "a", count: 64) + " trailing"])
    func onlyACompleteVersionAppropriateMACLineCanClose(value: String) {
        let lines = Array(Self.key().dropLast()) + ["Private-MAC: " + value, Self.key().last!, "after"]
        #expect(Redactor().redact(lines: lines).allSatisfy { $0.text == Self.marker })
    }

    @Test func metadataCannotSupplyAPrematureOrEmbeddedFooter() {
        var lines = Self.key()
        lines[2] = "Comment: Private-MAC: " + String(repeating: "a", count: 64)
        #expect(Redactor().redact(lines: lines + ["after"]).last?.text == "after")
        let premature = [lines[0], lines.last!, "after"]
        #expect(Redactor().redact(lines: premature).allSatisfy { $0.text == Self.marker })
    }

    @Test func theLargestCountDoesNotAllocateOrWrap() {
        var phase = Redactor.StreamState.PPKPhase.inactive
        for line in ["PuTTY-User-Key-File-3: ssh-rsa", "Private-Lines: \(Int.max)", "AAAA"] {
            #expect(Redactor.consumePPKLine(line, phase: &phase))
        }
        #expect(phase == .privateLines(remaining: Int.max - 1, macDigits: 64))
    }

    @Test func incompleteFilesRemainSensitiveAndStreamsAreIndependent() {
        let redactor = Redactor()
        var incomplete = Redactor.StreamState()
        for line in Self.key().dropLast() {
            #expect(redactor.redact(line: line, state: &incomplete).text == Self.marker)
        }
        #expect(incomplete.ppkPhase == .mac(digits: 64))
        #expect(redactor.redact(line: "after EOF without a MAC", state: &incomplete).text == Self.marker)
        #expect(incomplete.ppkPhase == .invalid)
        var independent = Redactor.StreamState()
        #expect(redactor.redact(line: "ordinary", state: &independent).text == "ordinary")
        incomplete = Redactor.StreamState()
        #expect(redactor.redact(line: "after reset", state: &incomplete).text == "after reset")
    }

    @Test(arguments: ["password: \"", "-----BEGIN PRIVATE KEY-----", "Authorization:", "password:", "Your code:"])
    func enclosingContextsAreNotClearedByAPrivateKey(prefix: String) {
        let redactor = Redactor()
        var state = Redactor.StreamState()
        _ = redactor.redact(line: prefix, state: &state)
        let outer = state
        for line in Self.key() { #expect(redactor.redact(line: line, state: &state).text == Self.marker) }
        #expect(state == outer)
        #expect(redactor.redact(line: "still sensitive", state: &state).text != "still sensitive")
    }

    @Test func terminalNormalizationDoesNotCountAVisibleBodyTwice() {
        var lines = Self.key()
        lines[0] = "\u{1B}[31m" + lines[0] + "\u{1B}[0m"
        lines[6] = "AA\u{1B}[31mAA"
        let output = Redactor().redact(lines: lines + ["after"]).map(\.text)
        #expect(output == Array(repeating: Self.marker, count: lines.count) + ["after"])
    }

    @Test func controlStringPayloadsNeitherOpenNorCloseAPrivateKey() {
        let redactor = Redactor()
        var state = Redactor.StreamState()
        #expect(redactor.redact(line: "\u{1B}]" + Self.key()[0] + "\u{07}", state: &state).text == "")
        #expect(state.ppkPhase == .inactive)
        for line in Self.key().dropLast() { _ = redactor.redact(line: line, state: &state) }
        #expect(redactor.redact(line: "\u{1B}]" + Self.key().last! + "\u{07}", state: &state).text == Self.marker)
        #expect(state.ppkPhase == .invalid)
        #expect(redactor.redact(line: Self.key().last!, state: &state).text == Self.marker)
        #expect(redactor.redact(line: "after", state: &state).text == Self.marker)
    }

    @Test func headerlessFragmentsDoNotArmAStream() {
        var phase = Redactor.StreamState.PPKPhase.inactive
        for line in ["PuTTY key format supported", "AAAA", "Private-Lines: 2"] {
            #expect(!Redactor.consumePPKLine(line, phase: &phase))
        }
        #expect(phase == .inactive)
    }

    @Test(arguments: ["1", "20", "0"])
    func unsupportedPrivateKeyVersionsRemainConservativelyClosed(version: String) {
        var state = Redactor.StreamState()
        for line in ["PuTTY-User-Key-File-\(version): ssh-rsa", "Private-Lines: 1", "syntheticKeyBody", "Private-Hash: " + String(repeating: "a", count: 40), "after"] {
            #expect(Redactor().redact(line: line, state: &state).text == Self.marker)
        }
        #expect(state.ppkPhase == .invalid)
    }
}
