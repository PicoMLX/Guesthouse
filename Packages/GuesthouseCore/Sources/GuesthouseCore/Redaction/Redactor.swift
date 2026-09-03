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
    /// Carried across `redact(line:state:)` calls so a PEM block split over many lines is
    /// removed in full.
    public struct StreamState: Hashable, Sendable {
        var insidePEMBlock = false

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
        var text = line

        if state.insidePEMBlock {
            if text.contains(Self.patterns.pemEnd) {
                state.insidePEMBlock = false
            }
            return RedactedLine(Self.marker("private-key"))
        }

        if let begin = text.firstRange(of: Self.patterns.pemBegin) {
            if let end = text.firstRange(of: Self.patterns.pemEnd), end.lowerBound >= begin.lowerBound {
                text.replaceSubrange(begin.lowerBound..<end.upperBound, with: Self.marker("private-key"))
            } else {
                state.insidePEMBlock = true
                text.replaceSubrange(begin.lowerBound..<text.endIndex, with: Self.marker("private-key"))
            }
        }

        return RedactedLine(Self.applyPatterns(to: text))
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

    // MARK: - Rules

    static func marker(_ kind: String) -> String { "[redacted:\(kind)]" }

    /// Compiled patterns. `Regex` is an immutable value type but is not declared `Sendable`,
    /// so this container vouches for it: nothing here is ever mutated after initialization.
    private struct Patterns: @unchecked Sendable {
        let pemBegin = #/-----BEGIN [A-Z0-9 ]+-----/#
        let pemEnd = #/-----END [A-Z0-9 ]+-----/#
        /// `Authorization: Basic xyz`, `Authorization: token xyz`, `Authorization: Bearer xyz`.
        let authorizationHeader = #/\bauthorization:\s*\S+(?:\s+\S+)?/#.ignoresCase()
        /// Bearer credentials outside a header line.
        let bearer = #/\bbearer\s+[A-Za-z0-9._~+\/=-]{8,}/#.ignoresCase()
        /// Classic and fine-grained GitHub tokens.
        let githubToken = #/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b/#
        /// OpenAI-style API keys.
        let apiKey = #/\bsk-[A-Za-z0-9_-]{16,}\b/#
        /// JSON Web Tokens.
        let jwt = #/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/#
        /// Credentials embedded in URLs: `https://user:secret@host`.
        let urlUserInfo = #/(:\/\/)[^\s\/@]+@/#
        /// `password: hunter2`, `passphrase=...`, `token=...`, `secret: "..."`, `api_key=...`.
        let labeledSecret = #/\b(password|passphrase|passwd|secret|token|api[_-]?key)\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|\S+)/#.ignoresCase()
        /// Device codes such as `1A2B-3C4D`, only on lines that mention a code, and never when
        /// the match is part of a longer hyphenated identifier such as a UUID.
        let mentionsCode = #/\bcodes?\b/#.ignoresCase()
        let deviceCode = #/(^|[^A-Za-z0-9-])([A-Z0-9]{4}-[A-Z0-9]{4})(?![A-Za-z0-9-])/#
    }

    private static let patterns = Patterns()

    private static func applyPatterns(to input: String) -> String {
        let p = patterns
        var text = input
        text = text.replacing(p.authorizationHeader, with: "Authorization: \(marker("authorization"))")
        text = text.replacing(p.bearer, with: "Bearer \(marker("bearer-token"))")
        text = text.replacing(p.githubToken, with: marker("github-token"))
        text = text.replacing(p.apiKey, with: marker("api-key"))
        text = text.replacing(p.jwt, with: marker("jwt"))
        text = text.replacing(p.urlUserInfo) { match in "\(match.1)\(marker("userinfo"))@" }
        text = text.replacing(p.labeledSecret) { match in "\(match.1): \(marker("secret"))" }
        if text.contains(p.mentionsCode) {
            text = applyDeviceCodePattern(to: text)
        }
        return text
    }

    static func applyDeviceCodePattern(to input: String) -> String {
        input.replacing(patterns.deviceCode) { match in "\(match.1)\(marker("device-code"))" }
    }
}
