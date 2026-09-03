import Foundation

/// Removes secrets from text before it can reach a log, the GUI, or a diagnostics export.
///
/// MVP-PLAN.md §3 ("Local storage"): private keys, tokens, device codes, authorization
/// headers, and raw authentication output must never be persisted or exported. The redactor
/// errs on the side of removing too much; over-redaction costs a little debuggability,
/// under-redaction leaks a credential.
///
/// Each removed secret is replaced by `[redacted:<kind>]` so a reader can still see what was
/// there and where.
public struct Redactor: Sendable {
    /// Carried across `redact(line:state:)` calls so a secret split over many lines is
    /// removed in full.
    public struct StreamState: Hashable, Sendable {
        /// The label of the PEM block being removed, until its matching footer.
        var pemLabel: String?
        /// The previous line was a bare `Authorization:` label; the value follows on this line.
        var expectingAuthorizationValue = false
        /// The previous line mentioned a code but carried none; the value may follow.
        var expectingDeviceCode = false

        public init() {}
    }

    public init() {}

    /// Redacts a complete text that may contain multiple lines.
    public func redact(_ text: String) -> String {
        var state = StreamState()
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { redact(line: String($0), state: &state).text }
            .joined(separator: "\n")
    }

    /// Redacts one line of a stream. Pass the same `state` for every line of one stream.
    public func redact(line: String, state: inout StreamState) -> RedactedLine {
        // Terminal styling is dropped first so an escape sequence can never sit between a word
        // boundary and a token.
        var text = Self.stripTerminalEscapes(line)

        if state.expectingAuthorizationValue {
            state.expectingAuthorizationValue = false
            // Any indented continuation is the folded value, however many parameters it has.
            if text.wholeMatch(of: Self.patterns.foldedContinuation) != nil {
                return RedactedLine(Self.marker("authorization"))
            }
        }
        if text.wholeMatch(of: Self.patterns.authorizationLabelOnly) != nil {
            state.expectingAuthorizationValue = true
            return RedactedLine("Authorization: \(Self.marker("authorization"))")
        }

        if let label = state.pemLabel {
            guard let footer = text.range(of: "-----END \(label)-----") else {
                return RedactedLine(Self.marker("private-key"))
            }
            // The block ends here; whatever follows the footer is scanned like any other text,
            // including another block that begins on the same line.
            state.pemLabel = nil
            text = Self.marker("private-key") + text[footer.upperBound...]
        }
        while let begin = text.firstMatch(of: Self.patterns.pemBegin) {
            let label = String(begin.1)
            if let end = text[begin.range.upperBound...].range(of: "-----END \(label)-----") {
                text.replaceSubrange(begin.range.lowerBound..<end.upperBound, with: Self.marker("private-key"))
            } else {
                state.pemLabel = label
                text.replaceSubrange(begin.range.lowerBound..<text.endIndex, with: Self.marker("private-key"))
                break
            }
        }

        // A blank line carries nothing and keeps the device-code context for the next one.
        if text.allSatisfy(\.isWhitespace) {
            return RedactedLine(text)
        }
        let codeExpected = state.expectingDeviceCode
        state.expectingDeviceCode = false
        // A header whose value may continue on an indented line keeps the continuation state.
        if text.contains(Self.patterns.authorizationLabel) {
            state.expectingAuthorizationValue = true
        }
        return RedactedLine(Self.applyPatterns(to: text, codeExpected: codeExpected, state: &state))
    }

    /// Redacts a single value that came from outside the app (a version string, a path, a
    /// component name) rather than a log line. Context is absent, so the device-code pattern
    /// applies unconditionally instead of only on lines that mention a code.
    public func redact(fieldValue: String) -> String {
        var state = StreamState()
        let line = redact(line: fieldValue, state: &state).text
        return Self.applyDeviceCodePattern(to: line)
    }

    /// Convenience for a batch of lines from one stream.
    public func redact(lines: [String]) -> [RedactedLine] {
        var state = StreamState()
        return lines.map { redact(line: $0, state: &state) }
    }

    /// Removes terminal control sequences: CSI in both encodings, OSC/DCS/APC/PM/SOS strings
    /// with their payloads, two-byte escapes, and bare C1 controls. Applied before any secret
    /// pattern so styling can never split a token or sit on a word boundary.
    public static func stripTerminalEscapes(_ text: String) -> String {
        text.replacing(patterns.terminalEscape, with: "")
    }

    // MARK: - Rules

    static func marker(_ kind: String) -> String { "[redacted:\(kind)]" }

    /// Compiled patterns. `Regex` is an immutable value type but is not declared `Sendable`,
    /// so this container vouches for it: nothing here is ever mutated after initialization.
    private struct Patterns: @unchecked Sendable {
        /// Control strings (OSC, DCS, APC, PM, SOS) up to BEL, ST, or the end of the line; CSI
        /// introduced by `ESC [` or U+009B; other two-byte escapes; and bare C1 controls.
        let terminalEscape = #/\u{1B}[\]P_^X][^\u{07}\u{9C}\u{1B}]*(?:\u{07}|\u{9C}|\u{1B}\\)?|[\u{9D}\u{90}\u{9F}\u{9E}\u{98}][^\u{07}\u{9C}\u{1B}]*(?:\u{07}|\u{9C}|\u{1B}\\)?|(?:\u{1B}\[|\u{9B})[0-9;:?<=>]*[ -\/]*[@-~]|\u{1B}[@-Z\\-_]|[\u{80}-\u{9F}]/#
        /// A folded header: the label alone on a line, value on the next.
        let authorizationLabelOnly = #/\s*"?authorization"?\s*:\s*/#.ignoresCase()
        /// Any authorization label, for lines whose value may continue on the next line.
        let authorizationLabel = #/\bauthorization\b"?\s*[:=]/#.ignoresCase()
        /// The continuation of a folded header: leading whitespace (folding requires it) and
        /// anything at all after it.
        let foldedContinuation = #/\s+\S.*/#
        let pemBegin = #/-----BEGIN ([A-Z0-9 ]+)-----/#
        /// The whole header value, quoted or to the end of the line, so multi-parameter schemes
        /// (Digest, AWS SigV4) leave nothing behind. The key may be quoted, as in JSON.
        let authorizationHeader = #/"?\bauthorization\b"?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\r\n]*)/#.ignoresCase()
        /// Bearer credentials outside a header line, of any length.
        let bearer = #/\bbearer\s+[A-Za-z0-9._~+\/=-]+/#.ignoresCase()
        /// Classic and fine-grained GitHub tokens.
        let githubToken = #/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b/#
        /// OpenAI-style API keys.
        let apiKey = #/\bsk-[A-Za-z0-9_-]{16,}\b/#
        /// JSON Web Tokens, matched structurally: three Base64URL segments (the last may be
        /// empty) whose first decodes to a JSON object, whitespace allowed.
        let jwt = #/\b([A-Za-z0-9_-]{4,})\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/#
        /// Credentials embedded in URLs: `https://user:secret@host`. The authority ends at the
        /// last `@` before a slash or whitespace, so a password containing `@` is fully covered.
        let urlUserInfo = #/(:\/\/)[^\s\/]+@/#
        /// `password: hunter2`, `passphrase=...`, `token=...`, `secret: "..."`, `"api_key":"..."`.
        let labeledSecret = #/"?\b(password|passphrase|passwd|secret|token|api[_-]?key)\b"?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)/#.ignoresCase()
        /// Device codes such as `1A2B-3C4D`, only on lines that mention a code (including the
        /// `user_code` and `device_code` field names of OAuth device flows), and never when the
        /// match is part of a longer hyphenated identifier such as a UUID.
        let mentionsCode = #/\b(?:codes?|(?:user|device)[_-]code)\b/#.ignoresCase()
        let deviceCode = #/(^|[^A-Za-z0-9-])([A-Z0-9]{4}-[A-Z0-9]{4})(?![A-Za-z0-9-])/#
    }

    private static let patterns = Patterns()

    private static func applyPatterns(to input: String, codeExpected: Bool, state: inout StreamState) -> String {
        let p = patterns
        var text = input
        text = text.replacing(p.authorizationHeader, with: "Authorization: \(marker("authorization"))")
        text = text.replacing(p.bearer, with: "Bearer \(marker("bearer-token"))")
        text = text.replacing(p.githubToken, with: marker("github-token"))
        text = text.replacing(p.apiKey, with: marker("api-key"))
        text = text.replacing(p.jwt) { match in isJOSEHeader(match.1) ? marker("jwt") : String(match.0) }
        text = text.replacing(p.urlUserInfo) { match in "\(match.1)\(marker("userinfo"))@" }
        text = text.replacing(p.labeledSecret) { match in "\(match.1): \(marker("secret"))" }
        let mentionsCode = text.contains(p.mentionsCode)
        if mentionsCode || codeExpected {
            let before = text
            text = applyDeviceCodePattern(to: text)
            // "Your one-time code is:" with the value on the next line.
            if mentionsCode, text == before {
                state.expectingDeviceCode = true
            }
        }
        return text
    }

    static func applyDeviceCodePattern(to input: String) -> String {
        input.replacing(patterns.deviceCode) { match in "\(match.1)\(marker("device-code"))" }
    }

    /// Whether a Base64URL segment decodes to text that starts a JSON object.
    static func isJOSEHeader(_ segment: Substring) -> Bool {
        var base64 = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return false }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return false }
        return String(decoding: data, as: UTF8.self).drop(while: \.isWhitespace).first == "{"
    }
}
