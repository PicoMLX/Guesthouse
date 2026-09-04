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
        /// The previous line was a bare `password:`-style label; the value follows on this line.
        var expectingSecretValue = false
        /// The previous line mentioned a code but carried none; the value may follow.
        var expectingDeviceCode = false
        /// A terminal control string opened on an earlier line and has not been terminated yet.
        var inControlString = false

        public init() {}
    }

    public init() {}

    /// Redacts a complete text that may contain multiple lines.
    public func redact(_ text: String) -> String {
        redact(text, codesAlwaysRedacted: false)
    }

    /// Redacts text that reached the app from somewhere else — decoded from JSON, received over
    /// XPC — where the surrounding context that makes a bare device code recognizable is gone.
    /// Device codes are therefore removed unconditionally, as in `redact(fieldValue:)`.
    public func redact(untrusted text: String) -> String {
        redact(text, codesAlwaysRedacted: true)
    }

    /// Redacts one line of a stream. Pass the same `state` for every line of one stream.
    public func redact(line: String, state: inout StreamState) -> RedactedLine {
        // Terminal styling is dropped first so an escape sequence can never sit between a word
        // boundary and a token.
        var text = Self.stripTerminalEscapes(line, inControlString: &state.inControlString)

        // A folded value runs over every consecutive indented line, so the state stays armed
        // until a line arrives that is not a continuation.
        let authorizationContinuation = state.expectingAuthorizationValue
            && text.wholeMatch(of: Self.patterns.foldedContinuation) != nil
        state.expectingAuthorizationValue = authorizationContinuation
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

        // The continuation's own text is all credential, but a PEM block it opens keeps running
        // over the lines that follow, so the block is detected above before the marker returns.
        if authorizationContinuation {
            return RedactedLine(Self.marker("authorization"))
        }

        // A blank line carries nothing and keeps the device-code context for the next one.
        if text.allSatisfy(\.isWhitespace) {
            return RedactedLine(text)
        }
        let codeExpected = state.expectingDeviceCode
        state.expectingDeviceCode = false
        // The previous line was a label with no value, so this line is the value itself and its
        // shape is unknown.
        if state.expectingSecretValue {
            state.expectingSecretValue = false
            return RedactedLine(Self.marker("secret"))
        }
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
        redact(untrusted: fieldValue)
    }

    /// Convenience for a batch of lines from one stream.
    public func redact(lines: [String]) -> [RedactedLine] {
        var state = StreamState()
        return lines.map { redact(line: $0, state: &state) }
    }

    private func redact(_ text: String, codesAlwaysRedacted: Bool) -> String {
        var state = StreamState()
        var result = ""
        var lineStart = text.startIndex
        func appendRedacted(_ line: Substring) {
            let redacted = redact(line: String(line), state: &state).text
            result += codesAlwaysRedacted ? Self.applyDeviceCodePattern(to: redacted) : redacted
        }
        // `\r\n` is one `Character`, so splitting on the newline character would leave a CRLF
        // stream as a single line and never apply the streaming rules to it. Each terminator is
        // put back exactly as it came in.
        for separator in text.matches(of: Self.patterns.lineSeparator) {
            appendRedacted(text[lineStart..<separator.range.lowerBound])
            result += separator.0
            lineStart = separator.range.upperBound
        }
        appendRedacted(text[lineStart...])
        return result
    }

    /// Removes terminal control sequences: CSI in both encodings, OSC/DCS/APC/PM/SOS strings
    /// with their payloads, escape sequences with or without intermediate bytes, and bare C1
    /// controls. Applied before any secret pattern so styling can never split a token or sit on
    /// a word boundary.
    public static func stripTerminalEscapes(_ text: String) -> String {
        text.replacing(patterns.terminalEscape, with: "")
    }

    /// The same, for one line of a stream: a control string may open on one line and terminate
    /// on a later one, and everything in between is its payload, not text to scan. Dropping that
    /// payload here also keeps the terminator from joining the words on either side of it.
    static func stripTerminalEscapes(_ line: String, inControlString: inout Bool) -> String {
        var text = line
        if inControlString {
            guard let terminator = text.firstMatch(of: patterns.controlStringEnd) else { return "" }
            text = String(text[terminator.range.upperBound...])
        }
        inControlString = text.contains(patterns.unterminatedControlString)
        return stripTerminalEscapes(text)
    }

    // MARK: - Rules

    static func marker(_ kind: String) -> String { "[redacted:\(kind)]" }

    /// Compiled patterns. `Regex` is an immutable value type but is not declared `Sendable`,
    /// so this container vouches for it: nothing here is ever mutated after initialization.
    private struct Patterns: @unchecked Sendable {
        /// Any of the three line terminators, CRLF first so it is never split in half.
        let lineSeparator = #/\r\n|\n|\r/#
        /// Control strings (OSC, DCS, APC, PM, SOS) up to BEL, ST, or the end of the line; CSI
        /// introduced by `ESC [` or U+009B; any other escape sequence, including the ones with
        /// intermediate bytes such as `ESC ( B`; and bare C1 controls.
        let terminalEscape = #/\u{1B}[\]P_^X][^\u{07}\u{9C}\u{1B}]*(?:\u{07}|\u{9C}|\u{1B}\\)?|[\u{9D}\u{90}\u{9F}\u{9E}\u{98}][^\u{07}\u{9C}\u{1B}]*(?:\u{07}|\u{9C}|\u{1B}\\)?|(?:\u{1B}\[|\u{9B})[0-9;:?<=>]*[ -\/]*[@-~]|\u{1B}[ -\/]*[0-~]|[\u{80}-\u{9F}]/#
        /// A control string introducer whose payload reaches the end of the line unterminated.
        let unterminatedControlString = #/(?:\u{1B}[\]P_^X]|[\u{9D}\u{90}\u{9F}\u{9E}\u{98}])[^\u{07}\u{9C}\u{1B}]*$/#
        /// The three ways a control string ends: BEL, C1 ST, or the two-byte ST.
        let controlStringEnd = #/\u{07}|\u{9C}|\u{1B}\\/#
        /// A folded header: the label alone on a line, value on the next.
        let authorizationLabelOnly = #/\s*(?:\\?["'])?authorization(?:\\?["'])?\s*:\s*/#.ignoresCase()
        /// Any authorization label, for lines whose value may continue on the next line.
        let authorizationLabel = #/(?:^|[^A-Za-z0-9])authorization\b(?:\\?["'])?\s*[:=]/#.ignoresCase()
        /// The continuation of a folded header: leading whitespace (folding requires it) and
        /// anything at all after it.
        let foldedContinuation = #/\s+\S.*/#
        let pemBegin = #/-----BEGIN ([A-Z0-9 ]+)-----/#
        /// The whole header value, quoted or to the end of the line, so multi-parameter schemes
        /// (Digest, AWS SigV4) leave nothing behind. The key may be quoted the way JSON, a
        /// Python dictionary, or a JSON string embedded in a log line quotes it.
        let authorizationHeader = #/(^|[^A-Za-z0-9])(?:\\?["'])?authorization\b(?:\\?["'])?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\r\n]*)/#.ignoresCase()
        /// Bearer credentials outside a header line, of any length. Every token and label rule
        /// here starts at a character that cannot be part of the word rather than at `\b`:
        /// Swift's word boundary is the Unicode one, where the dot in `<token>.partial`, in
        /// `cache.<token>`, or in `payload.Authorization` is not a break, and a secret beside
        /// one would survive. The character is captured so it can be put back. A label may also
        /// start after an underscore, which names most of them: `refresh_token`, `access_token`.
        let bearer = #/(^|[^A-Za-z0-9_])(bearer\s+[A-Za-z0-9._~+\/=-]+)/#.ignoresCase()
        /// Classic and fine-grained GitHub tokens.
        let githubToken = #/(^|[^A-Za-z0-9_])((?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/#
        /// OpenAI-style API keys.
        let apiKey = #/(^|[^A-Za-z0-9_])(sk-[A-Za-z0-9_-]{16,})/#
        /// JSON Web Tokens, matched structurally: Base64URL segments (the last may be empty) of
        /// which one decodes to a JSON object, whitespace allowed. More than three segments are
        /// taken because a JWT can follow a label, as in `session.<jwt>`.
        let jwt = #/(^|[^A-Za-z0-9_-])([A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]*){2,})/#
        /// Credentials embedded in URLs: `https://user:secret@host`. The authority ends at the
        /// last `@` before a slash or whitespace, so a password containing `@` is fully covered.
        let urlUserInfo = #/(:\/\/)[^\s\/]+@/#
        /// `password: hunter2`, `passphrase=...`, `token=...`, `secret: "..."`, `"api_key":"..."`.
        let labeledSecret = #/(^|[^A-Za-z0-9])"?(password|passphrase|passwd|secret|token|api[_-]?key)\b"?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)/#.ignoresCase()
        /// The same labels with nothing after the delimiter: CLI and pretty-printed output puts
        /// the value on the next line.
        let secretLabelOnly = #/(^|[^A-Za-z0-9])"?(password|passphrase|passwd|secret|token|api[_-]?key)\b"?\s*[:=]\s*$/#.ignoresCase()
        /// The explicit code fields of an OAuth device flow. Their values are opaque and their
        /// shape is the provider's choice, so the whole value goes, not just a `XXXX-XXXX` one.
        let codeField = #/(^|[^A-Za-z0-9])(?:\\?["'])?((?:user|device)[_-]code)\b(?:\\?["'])?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)/#.ignoresCase()
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
        text = text.replacing(p.authorizationHeader) { match in "\(match.1)Authorization: \(marker("authorization"))" }
        // Each token rule captures the character in front of the token, which is put back.
        text = text.replacing(p.bearer) { match in "\(match.1)Bearer \(marker("bearer-token"))" }
        text = text.replacing(p.githubToken) { match in "\(match.1)\(marker("github-token"))" }
        text = text.replacing(p.apiKey) { match in "\(match.1)\(marker("api-key"))" }
        text = text.replacing(p.jwt) { match in "\(match.1)\(redactedJWT(match.2))" }
        text = text.replacing(p.urlUserInfo) { match in "\(match.1)\(marker("userinfo"))@" }
        text = text.replacing(p.labeledSecret) { match in "\(match.1)\(match.2): \(marker("secret"))" }
        text = text.replacing(p.codeField) { match in "\(match.1)\(match.2): \(marker("device-code"))" }
        var labelAwaitsValue = false
        text = text.replacing(p.secretLabelOnly) { match in
            labelAwaitsValue = true
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretValue = labelAwaitsValue
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

    /// Replaces the three segments of a JWT inside a run of dot-separated segments. A dot is not
    /// a word boundary, so the run can begin with a label such as `session.`; every segment that
    /// has two behind it is tried as the JOSE header, and the segments around the token are kept.
    static func redactedJWT(_ candidate: Substring) -> String {
        let segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard let header = segments.indices.dropLast(2).first(where: { isJOSEHeader(segments[$0]) }) else {
            return String(candidate)
        }
        return (segments[..<header] + [Substring(marker("jwt"))] + segments[(header + 3)...]).joined(separator: ".")
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
