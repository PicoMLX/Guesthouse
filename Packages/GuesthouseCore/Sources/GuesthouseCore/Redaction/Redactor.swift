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

        struct QuotedValue: Hashable, Sendable {
            let delimiter: Character
            let escapeDepth: Int
            let kind: String
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
        /// A distinctive GitHub prefix reached a line boundary; payload may continue after it.
        var expectingGitHubContinuation = false
        /// Quoted values may wrap without indentation and remain sensitive until the quote closes.
        var quotedValue: QuotedValue?
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
        if let quoted = state.quotedValue {
            // Inspect the original normalized text: replacement markers no longer contain the
            // closing delimiter. A closing line is redacted whole, but its suffix can open a new
            // pending field. Blank/styling-only lines do not close the quoted value.
            if let end = Self.closingQuoteEnd(in: text[...], for: quoted) {
                state.quotedValue = nil
                state.expectingSecretValue = false
                state.expectingSecretContinuation = false
                state.expectingAuthorizationValue = false
                state.authorizationValueIsOnTheNextLine = false
                state.expectingDeviceCode = false
                _ = redact(line: String(text[end...]), state: &state)
            }
            return RedactedLine(text.isEmpty ? text : Self.marker(quoted.kind))
        }
        // What the boundary rendering armed, kept apart until this line's own pending contexts
        // have been consumed below and unioned in on the way out.
        var boundaryScan = StreamState()
        if stripped.spliced != stripped.joined {
            text = Self.applyPatterns(to: stripped.spliced, codeExpected: state.expectingDeviceCode, state: &boundaryScan)
                .replacingOccurrences(of: Self.splicedBoundary, with: "")
        }
        let githubRunsToLineEnd = stripped.joined.firstMatch(of: Self.patterns.githubTokenAtLineEnd) != nil
        if state.expectingGitHubContinuation, !text.allSatisfy(\.isWhitespace) {
            state.expectingGitHubContinuation = false
            if let continuation = text.firstMatch(of: Self.patterns.githubContinuation) {
                // Scan the original line for any following field/PEM context before replacing
                // its first token-shaped fragment. The normal scan still handles the suffix.
                Self.armPendingContexts(from: text, state: &boundaryScan)
                state.expectingGitHubContinuation = continuation.range.upperBound == text.endIndex
                text.replaceSubrange(continuation.range, with: Self.marker("github-token"))
            }
        }
        defer {
            state.expectingGitHubContinuation = state.expectingGitHubContinuation || githubRunsToLineEnd
            state.expectingAuthorizationValue = state.expectingAuthorizationValue || boundaryScan.expectingAuthorizationValue
            state.authorizationValueIsOnTheNextLine = state.authorizationValueIsOnTheNextLine || boundaryScan.authorizationValueIsOnTheNextLine
            state.expectingSecretValue = state.expectingSecretValue || boundaryScan.expectingSecretValue
            state.expectingSecretContinuation = state.expectingSecretContinuation || boundaryScan.expectingSecretContinuation
            state.expectingDeviceCode = state.expectingDeviceCode || boundaryScan.expectingDeviceCode
            state.quotedValue = state.quotedValue ?? boundaryScan.quotedValue
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
        let authorizationWasAwaitingValue = state.authorizationValueIsOnTheNextLine
        let unindentedValue = authorizationWasAwaitingValue
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
            state.quotedValue = Self.unterminatedQuote(in: text[...], kind: "authorization")
            if authorizationWasAwaitingValue, Self.valueStartsOnNextLine(text[...]) {
                state.authorizationValueIsOnTheNextLine = true
            }
            Self.armPendingContexts(from: text, state: &state)
            return RedactedLine(Self.marker("authorization"))
        }
        if secretContinuation {
            state.quotedValue = Self.unterminatedQuote(in: text[...], kind: "secret")
            if state.expectingSecretValue, !Self.valueStartsOnNextLine(text[...]) {
                state.expectingSecretValue = false
            }
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
            let secretExpected = state.expectingSecretValue
            let kind = secretExpected ? "secret" : "device-code"
            state.quotedValue = Self.unterminatedQuote(in: text[...], kind: kind)
            state.expectingSecretValue = false
            _ = Self.applyPatterns(to: text, codeExpected: false, state: &state)
            // The consumed value may fold onto further indented lines. A lone opening quote
            // still introduces a value rather than satisfying the pending context.
            if secretExpected {
                state.expectingSecretValue = state.expectingSecretValue || Self.valueStartsOnNextLine(text[...])
                state.expectingSecretContinuation = true
            } else if Self.valueStartsOnNextLine(text[...]) {
                state.expectingDeviceCode = true
            }
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
            result += codesAlwaysRedacted ? Self.applyDeviceCodePattern(to: redacted, preserveAlgorithms: true) : redacted
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
    /// with their payloads, escape sequences with or without intermediate bytes, and bare C0/C1
    /// controls. Tabs and line terminators retain their framing role; other controls are removed
    /// before secret matching so a backspace or styling sequence cannot interrupt a credential.
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
        var scanned = text.startIndex
        var joinedByteCount = 0
        var boundaryOffsets: [Int] = []
        for escape in text.matches(of: patterns.terminalEscape) {
            let literal = text[scanned..<escape.range.lowerBound]
            joined += literal
            joinedByteCount += literal.utf8.count
            if let before = text[..<escape.range.lowerBound].last, isTokenCharacter(before),
               let after = text[escape.range.upperBound...].first, isTokenCharacter(after) {
                boundaryOffsets.append(joinedByteCount)
            }
            scanned = escape.range.upperBound
        }
        joined += text[scanned...]
        guard !boundaryOffsets.isEmpty else { return (joined, joined) }

        // A boundary inside a recognized token would let the first scan redact only a valid
        // prefix. Closing the boundary afterwards cannot recover the remaining suffix. Keep
        // recognized tokens whole in both readings, while retaining boundaries before tokens
        // that need them, such as `filename<control>sk-...`.
        var tokenRanges = joined.matches(of: patterns.githubToken).map(\.range)
        // These structural spans intentionally omit the leading boundary: the boundary before
        // a token may itself need restoring. They only protect its interior from splitting;
        // the actual redaction rules still require their usual boundary.
        tokenRanges += joined.matches(of: #/sk-[A-Za-z0-9_-]{16,}/#).map(\.range)
        tokenRanges += joined.matches(of: #/bearer\s+[A-Za-z0-9._~+\/=-]+/#.ignoresCase()).map(\.range)
        tokenRanges += joined.matches(of: patterns.basicCredentialSpan).compactMap { match in
            isBasicCredential(match.2) ? match.range : nil
        }
        tokenRanges += joined.matches(of: patterns.digestCredentialSpan).map(\.range)
        tokenRanges += joined.matches(of: patterns.specializedCredentialSpan).map(\.range)
        tokenRanges += joined.matches(of: patterns.jwt).compactMap { match in
            redactedJWT(match.2) == String(match.2) ? nil : match.range
        }
        let byteRanges = tokenRanges.map { range -> Range<Int> in
            let lower = joined.utf8.distance(from: joined.utf8.startIndex, to: range.lowerBound)
            let upper = joined.utf8.distance(from: joined.utf8.startIndex, to: range.upperBound)
            return lower..<upper
        }.sorted { $0.lowerBound < $1.lowerBound }
        var mergedRanges: [Range<Int>] = []
        for range in byteRanges {
            if let last = mergedRanges.last, range.lowerBound < last.upperBound {
                mergedRanges[mergedRanges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                mergedRanges.append(range)
            }
        }
        var spliced = ""
        var rangeIndex = 0
        scanned = joined.startIndex
        for offset in boundaryOffsets {
            while rangeIndex < mergedRanges.count, mergedRanges[rangeIndex].upperBound <= offset {
                rangeIndex += 1
            }
            if rangeIndex < mergedRanges.count, mergedRanges[rangeIndex].lowerBound < offset {
                continue
            }
            let boundary = joined.utf8.index(joined.utf8.startIndex, offsetBy: offset)
            spliced += joined[scanned..<boundary]
            spliced += splicedBoundary
            scanned = boundary
        }
        spliced += joined[scanned...]
        return (joined, spliced)
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
        state.quotedValue = state.quotedValue ?? scanned.quotedValue
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
        /// bytes such as `ESC ( B`; and bare C0/C1 controls, except tabs and line terminators.
        /// OSC is the only control string that
        /// BEL ends — ECMA-48 gives DCS, APC, PM, and SOS the ST terminator alone — so a BEL
        /// inside one of those is payload. Ending them at it would hand the rest of the payload
        /// to the secret rules as text, and the character in front of a token there defeats the
        /// token rules' word boundary.
        let terminalEscape = #/(?:\u{1B}\]|\u{9D})[^\u{07}\u{9C}\u{1B}]*(?:\u{07}|\u{9C}|\u{1B}\\)?|(?:\u{1B}[P_^X]|[\u{90}\u{9F}\u{9E}\u{98}])[^\u{9C}\u{1B}]*(?:\u{9C}|\u{1B}\\)?|(?:\u{1B}\[|\u{9B})[0-9;:?<=>]*[ -\/]*[@-~]|\u{1B}[ -\/]*[0-~]|[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}\u{7F}-\u{9F}]/#
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
        let authorizationHeader = #/(^|[^A-Za-z0-9])(?:\\?["'])?(?:(?:proxy|request)[ _-]?)?authorization\b(?:\\?["'])?\s*[:=]\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\r\n]*)/#.ignoresCase()
        /// Bearer credentials outside a header line, of any length. Every token and label rule
        /// here starts at a character that cannot be part of the word rather than at `\b`:
        /// Swift's word boundary is the Unicode one, where the dot in `<token>.partial`, in
        /// `cache.<token>`, or in `payload.Authorization` is not a break, and a secret beside
        /// one would survive. The character is captured so it can be put back. A label may also
        /// start after an underscore, which names most of them: `refresh_token`, `access_token`.
        let bearer = #/(^|[^A-Za-z0-9])(bearer\s+[A-Za-z0-9._~+\/=-]+)/#.ignoresCase()
        /// A standalone authentication value can reach decoded diagnostics without its header
        /// name. Basic is recognized only when the Base64 decodes to a user/password separator;
        /// Digest must start with an authentication parameter assignment, not ordinary prose.
        private static var basicValue: Regex<(Substring, Substring, Substring)> {
            #/(basic[ \t]+)([A-Za-z0-9+\/]{2,}={0,2})(?![A-Za-z0-9+\/=])/#
        }
        let basicCredentialSpan = basicValue.ignoresCase()
        let basicAuthorization = Regex {
            #/(^|[^A-Za-z0-9])/#
            basicValue
        }.ignoresCase()
        private static var digestValue: Regex<Substring> {
            #/digest[ \t]+(?=(?:username\*?|realm|nonce|uri|response|algorithm|cnonce|opaque|qop|nc|userhash)\s*=)[^\r\n]+/#
        }
        let digestCredentialSpan = digestValue.ignoresCase()
        let digestAuthorization = Regex {
            #/(^|[^A-Za-z0-9])/#
            digestValue
        }.ignoresCase()
        /// Distinctive integrated-auth blobs and signed AWS requests remain recognizable after
        /// their header name is lost. Ordinary scheme-name prose alone is not a credential.
        private static var specializedValue: Regex<Substring> {
            #/(?:ntlm|negotiate)[ \t]+[A-Za-z0-9+\/_-]{8,}={0,2}|aws4-hmac-sha256[ \t]+(?=(?:credential|signedheaders|signature)\s*=)[^\r\n]+/#
        }
        let specializedCredentialSpan = specializedValue.ignoresCase()
        let specializedAuthorization = Regex {
            #/(^|[^A-Za-z0-9])/#
            specializedValue
        }.ignoresCase()
        /// Classic and fine-grained GitHub tokens. Nothing at all is required in front of the
        /// prefix, not even a delimiter: an untrusted file, branch, or cache name is glued
        /// straight onto a token by concatenation, and `artifactghp_...` carried a complete
        /// usable credential through a rule that only tolerated `artifact_ghp_...`. These
        /// prefixes are the reason it is safe to drop the boundary here — text that ends in
        /// `ghp`, `ghs`, or `github_pat` immediately before twenty alphanumerics is far rarer
        /// than the concatenation. The API-key rule below keeps its boundary, because `sk-` is
        /// three ordinary letters and dropping it there would redact `risk-averse-...`.
        /// Even a short fragment is sensitive once its distinctive prefix is present.
        let githubToken = #/(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]*|github_pat_[A-Za-z0-9_]*/#
        let githubTokenAtLineEnd = #/(?:(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]*|github_pat_[A-Za-z0-9_]*)$/#
        let githubContinuation = #/^[ \t]*[A-Za-z0-9_]+/#
        /// Distinctive project/provider prefixes survive filename concatenation. A generic
        /// `sk-` still needs its boundary so ordinary hyphenated words such as `risk-averse`
        /// remain intact.
        let apiKey = #/(^|[^A-Za-z0-9]|(?=sk-(?:proj|svcacct|ant)-))(sk-[A-Za-z0-9_-]{16,})/#
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
        /// A network-path reference can omit the scheme (`//user:secret@host`). Its leading
        /// delimiter must start a value, so doubled slashes inside a path or URL query do not
        /// turn an ordinary `@` later in that value into userinfo.
        let urlUserInfo = #/((?::|^|[\s"'(<\[{])(?:\\?\/){2})[^\s\/?#]+@/#
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
            #/(?:(?:access|refresh|auth|client|app|session|user|bearer|private|shared|signing|master|id|current|new|old|previous|confirm|confirmation)[ _-]?)?(?:password|passphrase|passwd|secret|token|credentials?|api[ _-]?key|private[ _-]?key|secret[ _-]?access[ _-]?key|access[ _-]?key[ _-]?secret)/#
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
            #/([ \t]+|=)(?=\S)/#
        }.ignoresCase()
        let secretOptionOnly = Regex {
            #/(^|\s)--?[A-Za-z0-9_-]*/#
            secretName
            #/[ \t]*(?:=[ \t]*)?$/#
        }.ignoresCase()
        /// The explicit code fields of an OAuth device flow. Their values are opaque and their
        /// shape is the provider's choice, so the whole value goes, not just a `XXXX-XXXX` one,
        /// and an unquoted one runs to the end of the line the way a labeled secret's does.
        let codeField = #/(^|[^A-Za-z0-9])(?:\\?["'])?((?:user|device)[ _-]?codes?)\b(?:\\?["'])?\s*[:=]\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S[^\r\n]*)/#.ignoresCase()
        /// The prose a CLI prints when it wants a code typed in — `Your one-time code is: …` —
        /// with the value on the same line. The value is as opaque as a field's, so all of it
        /// goes whatever its shape. The code has to be named: a line that merely contains the
        /// word, such as `process exited with code 1`, is a diagnostic, not a prompt. The
        /// `user_code` and `device_code` fields keep their own rule above, which keeps the field
        /// name in the output, so they are deliberately absent here.
        let codePrompt = #/((?:^|[^A-Za-z0-9])(?:\\?["'])?(?:your|one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access)[ _-]?codes?(?:\\?["'])?(?:\s+\S+){0,2}?\s*[:=])\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S[^\r\n]*)/#.ignoresCase()
        /// The same prompt with nothing after the delimiter: the value is on the next line. The
        /// device-flow field names are included, because arming the next line has no output whose
        /// shape has to be kept. A line that is nothing but `code:` is a prompt too — there is
        /// nothing else on it for the word to belong to.
        let codePromptOnly = #/(?:(?:^|[^A-Za-z0-9])(?:\\?["'])?(?:your|one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?(?:\\?["'])?(?:\s+\S+){0,2}?|^\s*codes?)\s*[:=]\s*$/#.ignoresCase()
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
        let declarativeCodePrompt = #/((?:^|[^A-Za-z0-9])(?:your|one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?\s+(?:is|are|reads|equals))(?:\s+("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s,;]+)|\s*$)/#.ignoresCase()
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

    private static func isBasicCredential(_ value: Substring) -> Bool {
        decodedBase64URL(value)?.contains(0x3A) == true
    }

    private static func unterminatedQuote(in value: Substring, kind: String) -> StreamState.QuotedValue? {
        let value = value.drop(while: { $0.isWhitespace })
        let slashes = value.prefix(while: { $0 == "\\" }).count
        let afterSlashes = value.dropFirst(slashes)
        guard let delimiter = afterSlashes.first, delimiter == "\"" || delimiter == "'" else { return nil }
        let quoted = StreamState.QuotedValue(delimiter: delimiter, escapeDepth: slashes, kind: kind)
        return closingQuoteEnd(in: afterSlashes.dropFirst(), for: quoted) == nil ? quoted : nil
    }

    private static func closingQuoteEnd(in value: Substring, for quoted: StreamState.QuotedValue) -> String.Index? {
        var slashes = 0
        for index in value.indices {
            let character = value[index]
            if character == "\\" {
                slashes += 1
                continue
            }
            if character == quoted.delimiter,
               quoted.escapeDepth == 0 ? slashes.isMultiple(of: 2) : slashes == quoted.escapeDepth {
                return value.index(after: index)
            }
            slashes = 0
        }
        return nil
    }

    private static func applyPatterns(to input: String, codeExpected: Bool, state: inout StreamState) -> String {
        let p = patterns
        var text = input
        // Recognition and continuation state use the original field, never its replacement
        // marker. Prefixes, quoting, and delimiters therefore cannot change the state policy.
        text = text.replacing(p.authorizationHeader) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.2, kind: "authorization")
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine =
                state.authorizationValueIsOnTheNextLine || valueStartsOnNextLine(match.2)
            return "\(match.1)Authorization: \(marker("authorization"))"
        }
        // Each token rule captures the character in front of the token, which is put back.
        text = text.replacing(p.bearer) { match in "\(match.1)Bearer \(marker("bearer-token"))" }
        text = text.replacing(p.basicAuthorization) { match in
            guard isBasicCredential(match.3) else { return String(match.0) }
            state.expectingAuthorizationValue = true
            return "\(match.1)Basic \(marker("authorization"))"
        }
        text = text.replacing(p.digestAuthorization) { match in
            state.expectingAuthorizationValue = true
            return "\(match.1)Digest \(marker("authorization"))"
        }
        text = text.replacing(p.specializedAuthorization) { match in
            state.expectingAuthorizationValue = true
            return "\(match.1)\(marker("authorization"))"
        }
        // The GitHub rule captures nothing in front of the token: it needs no boundary there.
        text = text.replacing(p.githubToken, with: marker("github-token"))
        text = text.replacing(p.apiKey) { match in "\(match.1)\(marker("api-key"))" }
        text = text.replacing(p.jwt) { match in "\(match.1)\(redactedJWT(match.2))" }
        text = text.replacing(p.urlUserInfo) { match in "\(match.1)\(marker("userinfo"))@" }
        // Scan argv boundaries before generic labelled values can consume following options.
        text = redactSecretOptions(text, state: &state)
        // A labeled value can be folded onto the next line, so the label arms the continuation
        // state the way an authorization header does.
        var labelCarriedAValue = false
        // Inspect the original input too: a preceding missing-value option may otherwise
        // consume this last option before the generic rules get to see it.
        var labelAwaitsValue = input.contains(p.secretOptionOnly)
        text = text.replacing(p.labeledSecret) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.3, kind: "secret")
            labelCarriedAValue = true
            labelAwaitsValue = labelAwaitsValue || valueStartsOnNextLine(match.3)
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretContinuation = labelCarriedAValue
        text = text.replacing(p.codeField) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.3, kind: "device-code")
            return "\(match.1)\(match.2): \(marker("device-code"))"
        }
        text = text.replacing(p.codePrompt) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.0.dropFirst(match.1.count), kind: "device-code")
            let punctuation = match.0.hasSuffix(".") ? "." : ""
            return "\(match.1) \(marker("device-code"))\(punctuation)"
        }
        text = text.replacing(p.codePromptWithoutDelimiter) { match in "\(match.1) \(marker("device-code"))" }
        text = text.replacing(p.declarativeCodePrompt) { match in
            if let value = match.2 {
                state.quotedValue = state.quotedValue ?? unterminatedQuote(in: value, kind: "device-code")
            }
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

    static func applyDeviceCodePattern(to input: String, preserveAlgorithms: Bool = false) -> String {
        input.replacing(patterns.deviceCode) { match in
            // Only context-free shape matching has this exception. Explicit credential fields
            // and code prompts still remove even a value that happens to name an algorithm.
            if preserveAlgorithms, match.2.wholeMatch(of: #/(?:HMAC|ECDSA|RSA)-SHA(?:1|224|256|384|512)|PBKDF2-HMAC-SHA(?:1|224|256|384|512)|CHACHA20-POLY1305/#) != nil {
                return String(match.0)
            }
            return "\(match.1)\(marker("device-code"))"
        }
    }

    /// Scan argument boundaries before replacing them. Plain shell quotes, quotes escaped by
    /// a surrounding diagnostic string, and escaped whitespace all belong to the same value.
    private static func redactSecretOptions(_ text: String, state: inout StreamState) -> String {
        var result = ""
        var cursor = text.startIndex
        while let match = text[cursor...].firstMatch(of: patterns.secretOption) {
            result += text[cursor..<match.range.lowerBound]
            // A missing value must not consume a later option's name and leave that option's
            // value unlabelled. Only a recognized secret option is left for another scan:
            // an opaque password beginning with a dash must still be removed.
            if match.3 != "=", text[match.range.upperBound...].prefixMatch(of: patterns.secretOption) != nil {
                result += match.0
                cursor = match.range.upperBound
                continue
            }
            let argument = secretArgument(in: text, from: match.range.upperBound)
            state.quotedValue = state.quotedValue ?? argument.quoted
            // Canonicalize equals to a space so the generic field rule cannot treat the
            // replacement and later arguments as a single unquoted passphrase.
            let separator = match.3 == "=" ? " " : String(match.3)
            result += "\(match.1)\(match.2)\(separator)\(marker("secret"))"
            cursor = argument.end
        }
        return result + text[cursor...]
    }

    private static func secretArgument(in text: String, from start: String.Index) -> (end: String.Index, quoted: StreamState.QuotedValue?) {
        var cursor = start
        var quote: Character?
        var quoteEscapeDepth = 0
        while cursor < text.endIndex {
            if quote == nil, text[cursor].isWhitespace { return (cursor, nil) }
            let escapeStart = cursor
            var escapeDepth = 0
            while cursor < text.endIndex, text[cursor] == "\\" {
                escapeDepth += 1
                text.formIndex(after: &cursor)
            }
            guard cursor < text.endIndex else { break }
            if let delimiter = quote {
                let closesQuote = quoteEscapeDepth == 0
                    ? escapeDepth.isMultiple(of: 2)
                    : escapeDepth == quoteEscapeDepth
                if text[cursor] == delimiter, closesQuote {
                    quote = nil
                }
            } else if text[cursor] == "\"" || text[cursor] == "'" {
                if escapeStart == start || escapeDepth.isMultiple(of: 2) {
                    quote = text[cursor]
                    // An encoded diagnostic quote can open at the beginning. Within a shell
                    // word, an odd backslash count escapes the quote as a literal character.
                    quoteEscapeDepth = escapeStart == start ? escapeDepth : 0
                }
            } else if text[cursor].isWhitespace, escapeDepth.isMultiple(of: 2) {
                return (cursor, nil)
            }
            text.formIndex(after: &cursor)
        }
        return (text.endIndex, quote.map { .init(delimiter: $0, escapeDepth: quoteEscapeDepth, kind: "secret") })
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

    /// Where the JOSE header begins inside a segment, including a header concatenated directly
    /// onto an alphanumeric filename. Every candidate suffix belongs to one of four Base64
    /// alignments. Decode each alignment once and find its balanced JSON-object suffix, instead
    /// of decoding successively shorter suffixes and doing quadratic work on a long filename.
    /// A candidate may include JSON whitespace before the opening brace.
    static func joseHeaderStart(_ segment: Substring) -> Substring.Index? {
        if isJOSEHeader(segment) { return segment.startIndex }
        var earliestOffset: Int?
        for alignment in 0..<min(4, segment.utf8.count) {
            let start = segment.index(segment.startIndex, offsetBy: alignment)
            guard let data = decodedBase64URL(segment[start...]) else { continue }
            let bytes = Array(data)
            guard let objectStart = jsonObjectSuffixStart(bytes) else { continue }
            var whitespaceStart = objectStart
            while whitespaceStart > 0, isJSONWhitespace(bytes[whitespaceStart - 1]) {
                whitespaceStart -= 1
            }
            // Four encoded bytes produce three decoded bytes. Only these decoded offsets
            // correspond to the beginning of a Base64-encoded suffix in this alignment.
            let decodedStart = ((whitespaceStart + 2) / 3) * 3
            guard decodedStart <= objectStart,
                  (try? JSONSerialization.jsonObject(with: Data(bytes[objectStart...]))) is [String: Any]
            else { continue }
            let encodedOffset = alignment + (decodedStart / 3) * 4
            earliestOffset = min(earliestOffset ?? encodedOffset, encodedOffset)
        }
        return earliestOffset.map { segment.index(segment.startIndex, offsetBy: $0) }
    }

    /// Finds the opening brace paired with the final non-whitespace closing brace. JSON parsing
    /// then validates that suffix; braces inside strings do not participate in the pairing.
    private static func jsonObjectSuffixStart(_ bytes: [UInt8]) -> Int? {
        guard var end = bytes.indices.last else { return nil }
        while isJSONWhitespace(bytes[end]) {
            guard end > 0 else { return nil }
            end -= 1
        }
        guard bytes[end] == 0x7D else { return nil }
        var depth = 0
        var insideString = false
        for index in stride(from: end, through: 0, by: -1) {
            let byte = bytes[index]
            if byte == 0x22 {
                var slashStart = index
                while slashStart > 0, bytes[slashStart - 1] == 0x5C { slashStart -= 1 }
                if (index - slashStart).isMultiple(of: 2) { insideString.toggle() }
            } else if !insideString {
                if byte == 0x7D { depth += 1 }
                if byte == 0x7B {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
        }
        return nil
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Whether a Base64URL segment decodes to a JOSE header object.
    static func isJOSEHeader(_ segment: Substring) -> Bool {
        joseSegmentCount(segment) != nil
    }

    /// The required JWE "enc" parameter distinguishes five-segment encrypted tokens from JWS.
    static func joseSegmentCount(_ segment: Substring) -> Int? {
        guard let data = decodedBase64URL(segment),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return header["enc"] == nil ? 3 : 5
    }

    private static func decodedBase64URL(_ segment: Substring) -> Data? {
        var base64 = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
