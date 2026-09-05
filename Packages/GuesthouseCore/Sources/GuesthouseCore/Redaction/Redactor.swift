import Foundation
import RegexBuilder

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
        /// Which kind of control string is open, because only an OSC also ends at BEL.
        enum ControlString: Hashable, Sendable {
            case osc
            case other
        }

        /// The label of the PEM block being removed, until its matching footer.
        var pemLabel: String?
        /// The previous line was a bare `Authorization:` label; the value follows on this line.
        var expectingAuthorizationValue = false
        /// That label carried no value of its own, so the next line is the value whether it is
        /// indented or not. A header that did carry one folds only over indented lines.
        var authorizationValueIsOnTheNextLine = false
        /// The previous line was a bare `password:`-style label; the value follows on this line.
        var expectingSecretValue = false
        /// The previous line labeled a secret and gave a value that may fold onto this one.
        var expectingSecretContinuation = false
        /// The previous line asked for a code but carried none; the value follows on this line.
        var expectingDeviceCode = false
        /// A terminal control string opened on an earlier line and has not been terminated yet.
        var openControlString: ControlString?

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
        // boundary and a token. Removing it joins the text on either side, which is what a label
        // split by styling needs, but it also hides the boundary every token rule requires in
        // front of a token: `prefix<ESC>[31mghp_...` becomes `prefixghp_...` and no rule matches
        // it. Both renderings are therefore scanned and what each removes is kept: one line can
        // hide a token behind a closed-up boundary and interrupt a label at the same time, and
        // then each rendering finds exactly one of the two, so choosing between them by how much
        // they removed leaks whichever the other would have found. The boundary rendering goes
        // first; what it leaves is closed up again for everything below, which is the rendering
        // a label has to be read in.
        let stripped = Self.stripTerminalEscapes(line, openControlString: &state.openControlString)
        var text = stripped.joined
        // What the boundary rendering armed, kept apart until this line's own pending contexts
        // have been consumed below and unioned in on the way out.
        var boundaryScan = StreamState()
        if stripped.spliced != stripped.joined {
            text = Self.applyPatterns(to: stripped.spliced, codeExpected: state.expectingDeviceCode, state: &boundaryScan)
                .replacingOccurrences(of: Self.splicedBoundary, with: "")
        }
        defer {
            state.expectingAuthorizationValue = state.expectingAuthorizationValue || boundaryScan.expectingAuthorizationValue
            state.authorizationValueIsOnTheNextLine = state.authorizationValueIsOnTheNextLine || boundaryScan.authorizationValueIsOnTheNextLine
            state.expectingSecretValue = state.expectingSecretValue || boundaryScan.expectingSecretValue
            state.expectingSecretContinuation = state.expectingSecretContinuation || boundaryScan.expectingSecretContinuation
            state.expectingDeviceCode = state.expectingDeviceCode || boundaryScan.expectingDeviceCode
        }

        // A folded value runs over every consecutive indented line, so the state stays armed
        // until a line arrives that is not a continuation. A blank line is not that line: a
        // styling-only line strips to nothing and the value still follows it, so the pending
        // authorization survives it exactly as the pending device code and secret do.
        let blankLine = text.allSatisfy(\.isWhitespace)
        // A header that put nothing after its colon has its value on the next line, and neither
        // a CLI nor a pretty-printer indents that line — folding is an HTTP wire rule. An
        // unindented line is therefore taken as that value unless it is itself a header, since
        // no later rule recognizes a bare `Basic dXNlcjpwYXNz` and the credential was being
        // returned unchanged. The test is what the line is, not which scheme it names: RFC 7235
        // keeps an open registry of authentication schemes, so a closed list of them let
        // `Custom opaqueCredential` through in full. `Accept: */*` is still the next header and
        // still drops the context. Once the value has started, further lines belong to it only
        // by being indented, which is what folding means.
        let unindentedValue = state.authorizationValueIsOnTheNextLine
            && text.firstMatch(of: Self.patterns.headerLabelStart) == nil
        let authorizationContinuation = state.expectingAuthorizationValue && !blankLine
            && (unindentedValue || text.wholeMatch(of: Self.patterns.foldedContinuation) != nil)
        if !blankLine {
            state.expectingAuthorizationValue = authorizationContinuation
            state.authorizationValueIsOnTheNextLine = false
        }
        // A labeled value folds the same way a header value does, and the second half of a
        // passphrase is as usable as the first.
        let secretContinuation = state.expectingSecretContinuation
            && text.wholeMatch(of: Self.patterns.foldedContinuation) != nil
        if !blankLine {
            state.expectingSecretContinuation = secretContinuation
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
        // A secret label or a code prompt inside the fold opens a context the *next* line
        // completes, and only a scan arms that, so the rules run here for their state alone.
        if authorizationContinuation {
            Self.armPendingContexts(from: text, state: &state)
            return RedactedLine(Self.marker("authorization"))
        }
        if secretContinuation {
            Self.armPendingContexts(from: text, state: &state)
            return RedactedLine(Self.marker("secret"))
        }

        // A blank line carries nothing and keeps the device-code context for the next one.
        if blankLine {
            return RedactedLine(text)
        }
        let codeExpected = state.expectingDeviceCode
        state.expectingDeviceCode = false
        // The previous line was a label or a code prompt with no value, so this whole line is
        // the value: its shape is the provider's choice, and a device code that is not
        // `XXXX-XXXX` would otherwise be returned intact. The line is still scanned, because
        // one credential prompt often follows another and only the scan arms the next state.
        if state.expectingSecretValue || codeExpected {
            let kind = state.expectingSecretValue ? "secret" : "device-code"
            state.expectingSecretValue = false
            _ = Self.applyPatterns(to: text, codeExpected: false, state: &state)
            return RedactedLine(Self.marker(kind))
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
        renderings(of: text).joined
    }

    /// The same, for one line of a stream: a control string may open on one line and terminate
    /// on a later one, and everything in between is its payload, not text to scan. Dropping that
    /// payload here also keeps the terminator from joining the words on either side of it.
    static func stripTerminalEscapes(
        _ line: String,
        openControlString: inout StreamState.ControlString?
    ) -> (joined: String, spliced: String) {
        var text = line
        if let open = openControlString {
            let end = open == .osc ? patterns.oscEnd : patterns.controlStringEnd
            guard let terminator = text.firstMatch(of: end) else { return ("", "") }
            text = String(text[terminator.range.upperBound...])
        }
        openControlString = text.firstMatch(of: patterns.unterminatedControlString)
            .map { $0.1 == nil ? .other : .osc }
        return renderings(of: text)
    }

    /// Stands where an escape did, in the `spliced` reading only. It has to be a boundary to
    /// every token rule and to be removable again afterwards without taking anything the line
    /// itself contained: `terminalEscape` matches every bare C1 control, so no scalar in this
    /// range survives stripping and every occurrence of this one in a stripped line is one this
    /// type put there.
    static let splicedBoundary = "\u{009F}"

    /// The two readings of a line whose terminal escapes have been removed: `joined`, where the
    /// text on either side of an escape closes up, and `spliced`, where an escape that stood
    /// between two characters a token can contain leaves a boundary behind. Only the second one
    /// shows where a token begins when styling was put in front of it; only the first one keeps
    /// a label that styling interrupted spelled correctly. `spliced` is `joined` when no escape
    /// stood in such a place, which is every ordinary line.
    private static func renderings(of text: String) -> (joined: String, spliced: String) {
        func isTokenCharacter(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        var joined = ""
        var spliced = ""
        var scanned = text.startIndex
        var splicedAnything = false
        for escape in text.matches(of: patterns.terminalEscape) {
            let literal = text[scanned..<escape.range.lowerBound]
            joined += literal
            spliced += literal
            if let before = text[..<escape.range.lowerBound].last, isTokenCharacter(before),
               let after = text[escape.range.upperBound...].first, isTokenCharacter(after) {
                spliced += splicedBoundary
                splicedAnything = true
            }
            scanned = escape.range.upperBound
        }
        let tail = text[scanned...]
        joined += tail
        spliced += tail
        return (joined, splicedAnything ? spliced : joined)
    }

    /// Runs the rules over a line that is replaced whole, so a secret label or a code prompt
    /// inside it still opens the context the next line completes. Nothing the rules produce is
    /// used, and a context that was already open stays open: this line is the value of the fold
    /// it continues, not the value that context is waiting for.
    private static func armPendingContexts(from text: String, state: inout StreamState) {
        var scanned = state
        _ = applyPatterns(to: text, codeExpected: false, state: &scanned)
        state.expectingAuthorizationValue = state.expectingAuthorizationValue || scanned.expectingAuthorizationValue
        state.authorizationValueIsOnTheNextLine = state.authorizationValueIsOnTheNextLine || scanned.authorizationValueIsOnTheNextLine
        state.expectingSecretValue = state.expectingSecretValue || scanned.expectingSecretValue
        state.expectingSecretContinuation = state.expectingSecretContinuation || scanned.expectingSecretContinuation
        state.expectingDeviceCode = state.expectingDeviceCode || scanned.expectingDeviceCode
    }

    // MARK: - Rules

    static func marker(_ kind: String) -> String { "[redacted:\(kind)]" }

    /// Compiled patterns. `Regex` is an immutable value type but is not declared `Sendable`,
    /// so this container vouches for it: nothing here is ever mutated after initialization.
    private struct Patterns: @unchecked Sendable {
        /// Any of the three line terminators, CRLF first so it is never split in half.
        let lineSeparator = #/\r\n|\n|\r/#
        /// Control strings up to their terminator or the end of the line, then CSI introduced by
        /// `ESC [` or U+009B; any other escape sequence, including the ones with intermediate
        /// bytes such as `ESC ( B`; and bare C1 controls. OSC is the only control string that
        /// BEL ends — ECMA-48 gives DCS, APC, PM, and SOS the ST terminator alone — so a BEL
        /// inside one of those is payload. Ending them at it would hand the rest of the payload
        /// to the secret rules as text, and the character in front of a token there defeats the
        /// token rules' word boundary.
        let terminalEscape = #/(?:\u{1B}\]|\u{9D})[^\u{07}\u{9C}\u{1B}]*(?:\u{07}|\u{9C}|\u{1B}\\)?|(?:\u{1B}[P_^X]|[\u{90}\u{9F}\u{9E}\u{98}])[^\u{9C}\u{1B}]*(?:\u{9C}|\u{1B}\\)?|(?:\u{1B}\[|\u{9B})[0-9;:?<=>]*[ -\/]*[@-~]|\u{1B}[ -\/]*[0-~]|[\u{80}-\u{9F}]/#
        /// A control string introducer whose payload reaches the end of the line unterminated.
        /// The first capture is present only for an OSC, whose payload a later BEL also ends.
        let unterminatedControlString = #/(?:(\u{1B}\]|\u{9D})[^\u{07}\u{9C}\u{1B}]*|(?:\u{1B}[P_^X]|[\u{90}\u{9F}\u{9E}\u{98}])[^\u{9C}\u{1B}]*)$/#
        /// The two ways any control string ends: C1 ST or the two-byte ST.
        let controlStringEnd = #/\u{9C}|\u{1B}\\/#
        /// An OSC ends at either of those or at BEL.
        let oscEnd = #/\u{07}|\u{9C}|\u{1B}\\/#
        /// The continuation of a folded header: leading whitespace (folding requires it) and
        /// anything at all after it.
        let foldedContinuation = #/\s+\S.*/#
        /// A line that opens with a header field name and its colon. Used the other way round
        /// from the rules here: a line that matches is the *next header*, and everything else
        /// standing unindented under a bare authorization label is that label's value.
        let headerLabelStart = #/^\s*(?:\\?["'])?[A-Za-z0-9][A-Za-z0-9-]*(?:\\?["'])?\s*:/#
        /// A PEM header. RFC 7468 labels are not only upper-case letters and spaces: they carry
        /// hyphens, digits, and dots (`ACME-PRIVATE KEY`, `X9.42 DH PARAMETERS`), and a label
        /// this rule cannot spell leaves the block, header and key material alike, in the clear.
        /// The label is matched lazily and has to end on an alphanumeric, so it can never eat
        /// the closing dashes and a second block on the same line stays its own match.
        let pemBegin = #/-----BEGIN ([A-Za-z0-9](?:[A-Za-z0-9 ._+-]*?[A-Za-z0-9])?)-----/#
        /// The whole header value, quoted or to the end of the line, so multi-parameter schemes
        /// (Digest, AWS SigV4) leave nothing behind. The key may be quoted the way JSON, a
        /// Python dictionary, or a JSON string embedded in a log line quotes it.
        /// The same match determines continuation state before replacement. An empty value
        /// arms the next line even when a logger prefixes or quotes the field name.
        let authorizationHeader = #/(^|[^A-Za-z0-9])(?:\\?["'])?authorization\b(?:\\?["'])?\s*[:=]\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\r\n]*)/#.ignoresCase()
        /// Bearer credentials outside a header line, of any length. Every token and label rule
        /// here starts at a character that cannot be part of the word rather than at `\b`:
        /// Swift's word boundary is the Unicode one, where the dot in `<token>.partial`, in
        /// `cache.<token>`, or in `payload.Authorization` is not a break, and a secret beside
        /// one would survive. The character is captured so it can be put back. A label may also
        /// start after an underscore, which names most of them: `refresh_token`, `access_token`.
        let bearer = #/(^|[^A-Za-z0-9_])(bearer\s+[A-Za-z0-9._~+\/=-]+)/#.ignoresCase()
        /// Classic and fine-grained GitHub tokens. Nothing at all is required in front of the
        /// prefix, not even a delimiter: an untrusted file, branch, or cache name is glued
        /// straight onto a token by concatenation, and `artifactghp_...` carried a complete
        /// usable credential through a rule that only tolerated `artifact_ghp_...`. These
        /// prefixes are the reason it is safe to drop the boundary here — text that ends in
        /// `ghp`, `ghs`, or `github_pat` immediately before twenty alphanumerics is far rarer
        /// than the concatenation. The API-key rule below keeps its boundary, because `sk-` is
        /// three ordinary letters and dropping it there would redact `risk-averse-...`.
        let githubToken = #/(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}/#
        /// OpenAI-style API keys.
        let apiKey = #/(^|[^A-Za-z0-9])(sk-[A-Za-z0-9_-]{16,})/#
        /// JSON Web Tokens, matched structurally: Base64URL segments (the last may be empty) of
        /// which one decodes to a JSON object, whitespace allowed. More than three segments are
        /// taken because a JWT can follow a label, as in `session.<jwt>`.
        let jwt = #/(^|[^A-Za-z0-9_-])([A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]*){2,})/#
        /// Credentials embedded in URLs: `https://user:secret@host`. The authority ends at the
        /// last `@` before a slash or whitespace, so a password containing `@` is fully covered.
        /// It also ends at `?` and `#`, which end an authority exactly as `/` does (RFC 3986):
        /// without them `https://example.com?email=user@example.org` reads its query's `@` as
        /// userinfo and rewrites a legitimate link into `https://[redacted:userinfo]@example.org`.
        /// Nothing that is really userinfo is lost, because a `?` inside one has to be
        /// percent-encoded for the text to be a URL at all.
        /// A URL that reached a log through JSON keeps that encoding's escaped slashes.
        let urlUserInfo = #/(:(?:\\?\/){2})[^\s\/?#]+@/#
        /// `password: hunter2`, `passphrase=...`, `token=...`, `secret: "..."`, `"api_key":"..."`,
        /// and the camel-case keys structured diagnostics use: `accessToken`, `refreshToken`,
        /// `clientSecret`. Those need a name in front of the label word, and the names come from
        /// a closed list so that an ordinary word ending in `token` or `secret` is still not a
        /// label. The key is quoted the way JSON, a Python dictionary, or a JSON string embedded
        /// in a log line quotes it. An unquoted value runs to the end of the line rather than to
        /// the first space, because a passphrase is words: `password: correct horse battery`. It
        /// still has to start with one non-space character, so a bare label falls to the rule
        /// below and arms the next line instead of matching an empty value here.
        /// One vocabulary shared by inline fields, bare labels, and command options.
        /// Explicit private-key labels are sensitive even when the value is not PEM.
        private static var secretName: Regex<Substring> {
            #/(?:(?:access|refresh|auth|client|app|session|user|bearer|private|shared|signing|master|id)[ _-]?)?(?:password|passphrase|passwd|secret|token|api[ _-]?key|private[ _-]?key)/#
        }
        private static var secretLabel: Regex<(Substring, Substring, Substring)> {
            Regex {
                #/(^|[^A-Za-z0-9])(?:\\?["'])?/#
                Capture { secretName }
                #/\b(?:\\?["'])?\s*[:=]\s*/#
            }
        }
        let labeledSecret = Regex {
            secretLabel
            Capture {
                #/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S[^\r\n]*/#
            }
        }.ignoresCase()
        /// The same labels with nothing after the delimiter: CLI and pretty-printed output puts
        /// the value on the next line.
        let secretLabelOnly = Regex {
            secretLabel
            Anchor.endOfSubject
        }.ignoresCase()
        /// The same secret named as a command-line option, which CLI diagnostics echo back
        /// verbatim: `--password hunter2`, `--github-token opaqueCredential`. There is no `:`
        /// or `=` to key on, so the leading dash is what makes this a secret rather than the
        /// word `token` in a sentence. The value is one argv word, or a quoted one, rather than
        /// the rest of the line: an echoed command line carries the options after it, and
        /// `--token abc --verbose` must keep its second option.
        let secretOption = Regex {
            #/(^|\s)/#
            Capture {
                #/--?[A-Za-z0-9_-]*/#
                secretName
            }
            #/(\s+)(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)/#
        }.ignoresCase()
        /// The explicit code fields of an OAuth device flow. Their values are opaque and their
        /// shape is the provider's choice, so the whole value goes, not just a `XXXX-XXXX` one,
        /// and an unquoted one runs to the end of the line the way a labeled secret's does.
        let codeField = #/(^|[^A-Za-z0-9])(?:\\?["'])?((?:user|device)[ _-]codes?)\b(?:\\?["'])?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S[^\r\n]*)/#.ignoresCase()
        /// The prose a CLI prints when it wants a code typed in — `Your one-time code is: …` —
        /// with the value on the same line. The value is as opaque as a field's, so all of it
        /// goes whatever its shape. The code has to be named: a line that merely contains the
        /// word, such as `process exited with code 1`, is a diagnostic, not a prompt. The
        /// `user_code` and `device_code` fields keep their own rule above, which keeps the field
        /// name in the output, so they are deliberately absent here.
        let codePrompt = #/((?:^|[^A-Za-z0-9])(?:\\?["'])?(?:one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access)[ _-]?codes?(?:\\?["'])?(?:\s+\S+){0,2}?\s*[:=])\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S[^\r\n]*)/#.ignoresCase()
        /// The same prompt with nothing after the delimiter: the value is on the next line. The
        /// device-flow field names are included, because arming the next line has no output whose
        /// shape has to be kept. A line that is nothing but `code:` is a prompt too — there is
        /// nothing else on it for the word to belong to.
        let codePromptOnly = #/(?:(?:^|[^A-Za-z0-9])(?:\\?["'])?(?:one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?(?:\\?["'])?(?:\s+\S+){0,2}?|^\s*codes?)\s*[:=]\s*$/#.ignoresCase()
        /// Device codes such as `1A2B-3C4D` and the `WDJB.MJHT` an RFC 8628 provider may print:
        /// runs of four to eight upper-case characters joined by single separators. Applied only
        /// on lines that mention a code (including the `user_code` and `device_code` field names
        /// of OAuth device flows), and never when the match is part of a longer hyphenated or
        /// dotted identifier such as a UUID or a reverse-DNS name.
        let mentionsCode = #/\b(?:codes?|(?:user|device)[_-]code)\b/#.ignoresCase()
        /// The trailing exclusion covers a dot that continues the identifier as well as a letter,
        /// a digit, or a hyphen: without it `ABCD-EFGH.example.com` becomes
        /// `[redacted:device-code].example.com`, which is the longer dotted identifier this rule
        /// says it leaves alone. A dot that ends a sentence is not one, so `your code: AB12-CD34.`
        /// still loses its code.
        let deviceCode = #/(^|[^A-Za-z0-9.-])([A-Z0-9]{4,8}(?:[-.][A-Z0-9]{4,8}){1,3})(?![A-Za-z0-9-]|\.[A-Za-z0-9])/#
        /// A prompt that names the code with no delimiter at all: `Enter the code ABC123 at the
        /// URL shown` is the prose an RFC 8628 provider prints, and only a value that happens to
        /// have the dotted or hyphenated shape above was removed from it. Two forms qualify: the
        /// imperative one, which asks for the code, and a historical declaration with a copula.
        /// Present-tense declarations also have the opaque-value rule below. Here a value has
        /// to look like a code rather than
        /// like the next English word: four or more characters that are all upper-case or
        /// digits, or that carry a digit. `process exited with code 1`, `Enter the code shown
        /// below`, and `the login code was rejected` are all left alone. The words are matched
        /// without regard to case; the value's own alternatives are not, or every lower-case
        /// word after the label would be a code.
        let codePromptWithoutDelimiter = #/((?:^|[^A-Za-z0-9])(?:(?i:(?:enter|type|paste|copy|input)(?:\s+\S+){0,3}?\s+codes?)|(?i:(?:one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?(?:\s+(?:is|are|was|were|reads|equals))+)))\s+(?=[A-Za-z0-9._-]{4})(?:[A-Z0-9._-]+|[A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]*)(?![A-Za-z0-9._-])/#
        /// Present-tense declarations explicitly supply the code. Lowercase, short, and
        /// quoted values are opaque. Historical status prose keeps the conservative rule above.
        let declarativeCodePrompt = #/((?:^|[^A-Za-z0-9])(?:one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?\s+(?:is|are|reads|equals))(?:\s+("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s,;]+)|\s*$)/#.ignoresCase()
    }

    private static let patterns = Patterns()

    /// Pretty-printed values may start after an empty label or an opening quote on its own.
    /// A completed empty string is already a value and must not consume the following line.
    private static func valueStartsOnNextLine(_ value: Substring) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "", "\"", "'", "\\\"", "\\'": true
        default: false
        }
    }

    private static func applyPatterns(to input: String, codeExpected: Bool, state: inout StreamState) -> String {
        let p = patterns
        var text = input
        // Recognition and continuation state use the original field, never its replacement
        // marker. Prefixes, quoting, and delimiters therefore cannot change the state policy.
        text = text.replacing(p.authorizationHeader) { match in
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine =
                state.authorizationValueIsOnTheNextLine || valueStartsOnNextLine(match.2)
            return "\(match.1)Authorization: \(marker("authorization"))"
        }
        // Each token rule captures the character in front of the token, which is put back.
        text = text.replacing(p.bearer) { match in "\(match.1)Bearer \(marker("bearer-token"))" }
        // The GitHub rule captures nothing in front of the token: it needs no boundary there.
        text = text.replacing(p.githubToken, with: marker("github-token"))
        text = text.replacing(p.apiKey) { match in "\(match.1)\(marker("api-key"))" }
        text = text.replacing(p.jwt) { match in "\(match.1)\(redactedJWT(match.2))" }
        text = text.replacing(p.urlUserInfo) { match in "\(match.1)\(marker("userinfo"))@" }
        // A labeled value can be folded onto the next line, so the label arms the continuation
        // state the way an authorization header does.
        var labelCarriedAValue = false
        var labelAwaitsValue = false
        text = text.replacing(p.labeledSecret) { match in
            labelCarriedAValue = true
            labelAwaitsValue = labelAwaitsValue || valueStartsOnNextLine(match.3)
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretContinuation = labelCarriedAValue
        // The option keeps its name and the spacing that followed it, so an echoed command line
        // still reads as one: `--password [redacted:secret] --verbose`.
        text = text.replacing(p.secretOption) { match in "\(match.1)\(match.2)\(match.3)\(marker("secret"))" }
        text = text.replacing(p.codeField) { match in "\(match.1)\(match.2): \(marker("device-code"))" }
        text = text.replacing(p.codePrompt) { match in "\(match.1) \(marker("device-code"))" }
        text = text.replacing(p.codePromptWithoutDelimiter) { match in "\(match.1) \(marker("device-code"))" }
        text = text.replacing(p.declarativeCodePrompt) { match in
            state.expectingDeviceCode = state.expectingDeviceCode
                || (match.2.map(valueStartsOnNextLine) ?? true)
            return "\(match.1) \(marker("device-code"))"
        }
        text = text.replacing(p.secretLabelOnly) { match in
            labelAwaitsValue = true
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretValue = labelAwaitsValue
        if text.contains(p.mentionsCode) || codeExpected {
            text = applyDeviceCodePattern(to: text)
        }
        // "Your one-time code is:" with the value on the next line. Only a line that asks for a
        // code arms the next one: arming on any mention of the word would replace the failure
        // that follows `process exited with code 1` with a device-code marker.
        if text.contains(p.codePromptOnly) {
            state.expectingDeviceCode = true
        }
        return text
    }

    static func applyDeviceCodePattern(to input: String) -> String {
        input.replacing(patterns.deviceCode) { match in "\(match.1)\(marker("device-code"))" }
    }

    /// Replaces all three JWS or five JWE segments inside a run of dot-separated segments. A dot is
    /// not a word boundary, so the run can begin with a label such as `session.` and can hold two
    /// adjacent tokens; every segment with at least two following it is tried as a JOSE header, and the
    /// segments around the tokens are kept.
    static func redactedJWT(_ candidate: Substring) -> String {
        var segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        var index = segments.startIndex
        while index + 2 < segments.count {
            if let start = joseHeaderStart(segments[index]) {
                let name = segments[index][..<start]
                let count = joseSegmentCount(segments[index][start...]) ?? 3
                // A truncated token is still sensitive; remove all available token segments.
                let end = min(index + count, segments.endIndex)
                segments.replaceSubrange(index..<end, with: [name + Substring(marker("jwt"))])
            }
            index += 1
        }
        return segments.joined(separator: ".")
    }

    /// Where the JOSE header begins inside a segment. `_` and `-` are Base64URL characters, so
    /// the rule above cannot treat them as boundaries without folding a token's own first
    /// characters into the name in front of it; an untrusted file or cache name is glued on with
    /// exactly those, as in `artifact_<jwt>`, so the header is looked for after each of them too.
    /// The name is returned along with it and put back.
    static func joseHeaderStart(_ segment: Substring) -> Substring.Index? {
        if isJOSEHeader(segment) { return segment.startIndex }
        var start = segment.startIndex
        while let separator = segment[start...].firstIndex(where: { $0 == "_" || $0 == "-" }) {
            start = segment.index(after: separator)
            if start < segment.endIndex, isJOSEHeader(segment[start...]) { return start }
        }
        return nil
    }

    /// Whether a Base64URL segment decodes to a JOSE header object.
    static func isJOSEHeader(_ segment: Substring) -> Bool {
        joseSegmentCount(segment) != nil
    }

    /// The required JWE "enc" parameter distinguishes five-segment encrypted tokens from JWS.
    static func joseSegmentCount(_ segment: Substring) -> Int? {
        var base64 = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return header["enc"] == nil ? 3 : 5
    }
}
