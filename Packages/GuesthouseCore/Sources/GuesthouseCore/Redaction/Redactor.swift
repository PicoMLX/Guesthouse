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
        /// Which credential the previous record was carrying when it ended without a line
        /// ending. A reader that cuts an over-long line hands the rest over as another record,
        /// and that tail is the same value.
        var continuedValue: ContinuedValue?

        /// A credential whose value the previous record was still spelling out.
        enum ContinuedValue: Hashable, Sendable {
            case secret
            case deviceCode

            var kind: String { self == .secret ? "secret" : "device-code" }
        }

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
        redact(line: line, continuesPreviousRecord: false, state: &state)
    }

    /// Redacts one line of a stream.
    ///
    /// `continuesPreviousRecord` says that this text is the tail of a line a reader had to cut
    /// because it was too long to keep whole, rather than a line of its own. The cut can fall
    /// on any byte, so such a tail is not required to look like a folded continuation the way
    /// a genuinely new line is: whatever the previous record established still applies, and a
    /// header value cut away from its label at a comma is removed exactly as one cut at a
    /// space would be.
    public func redact(line: String, continuesPreviousRecord: Bool, state: inout StreamState) -> RedactedLine {
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
        // by being indented, which is what folding means — or by continuing the record the
        // reader cut, which is not a line break the writer made at all.
        let unindentedValue = state.authorizationValueIsOnTheNextLine
            && text.firstMatch(of: Self.patterns.headerLabelStart) == nil
        let authorizationContinuation = state.expectingAuthorizationValue && !blankLine
            && (unindentedValue || continuesPreviousRecord
                || text.wholeMatch(of: Self.patterns.foldedContinuation) != nil)
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
        if text.wholeMatch(of: Self.patterns.authorizationLabelOnly) != nil {
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine = true
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
        // The label that armed a pending value, or that introduced one running to the end of
        // the line, was consumed by an earlier record of the same line. Re-arming here is what
        // removes the rest of a password or a device code: its shape is the provider's choice,
        // so nothing below would recognize the tail on its own and it would go out verbatim.
        if continuesPreviousRecord {
            switch state.continuedValue {
            case .secret: state.expectingSecretValue = true
            case .deviceCode: state.expectingDeviceCode = true
            case nil: break
            }
        }
        state.continuedValue = nil
        let codeExpected = state.expectingDeviceCode
        state.expectingDeviceCode = false
        // A header whose value may continue on an indented line keeps the continuation state.
        if text.contains(Self.patterns.authorizationLabel) {
            state.expectingAuthorizationValue = true
        }
        // The previous line was a label or a code prompt with no value, so this whole line is
        // the value: its shape is the provider's choice, and a device code that is not
        // `XXXX-XXXX` would otherwise be returned intact. The line is still scanned, because
        // one credential prompt often follows another and only the scan arms the next state.
        if state.expectingSecretValue || codeExpected {
            let value: StreamState.ContinuedValue = state.expectingSecretValue ? .secret : .deviceCode
            state.expectingSecretValue = false
            _ = Self.applyPatterns(to: text, codeExpected: false, state: &state)
            // Whatever a forced cut left of this value is the same value.
            state.continuedValue = value
            return RedactedLine(Self.marker(value.kind))
        }
        return RedactedLine(Self.applyPatterns(to: text, codeExpected: codeExpected, state: &state))
    }

    /// Redacts a single value that came from outside the app (a version string, a path, a
    /// component name) rather than a log line. Context is absent, so the device-code pattern
    /// applies unconditionally instead of only on lines that mention a code.
    public func redact(fieldValue: String) -> String {
        redact(untrusted: fieldValue)
    }

    /// Redacts one line of child-process output: everything `redact(line:state:)` does, and
    /// the device-code rule unconditionally, because an authentication CLI may print a bare
    /// code on a line of its own.
    public func redact(processOutputLine line: String, state: inout StreamState) -> RedactedLine {
        redact(processOutputLine: line, continuesPreviousRecord: false, state: &state)
    }

    /// One record of child-process output, saying whether it is the tail of a line the reader
    /// had to cut rather than a line of its own. See `redact(line:continuesPreviousRecord:state:)`.
    public func redact(processOutputLine line: String, continuesPreviousRecord: Bool, state: inout StreamState) -> RedactedLine {
        let first = redact(line: line, continuesPreviousRecord: continuesPreviousRecord, state: &state)
        return RedactedLine(Self.applyDeviceCodePattern(to: first.text))
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
        state.expectingSecretValue = state.expectingSecretValue || scanned.expectingSecretValue
        state.expectingSecretContinuation = state.expectingSecretContinuation || scanned.expectingSecretContinuation
        state.expectingDeviceCode = state.expectingDeviceCode || scanned.expectingDeviceCode
    }

    /// Replaces every whitespace-delimited run holding an escape sequence that may have taken a
    /// character of the value with it.
    ///
    /// An escape sequence ends on its final byte, so an introducer planted directly in front of
    /// a secret makes that secret's own character the terminator, and it disappears with the
    /// sequence: `AB12-ESC[CD34`, `AB12-ESC[0CD34`, and `AB12-ESC(CD34` all strip to
    /// `AB12-D34`, a near-complete device code no pattern below recognizes. Parameters and
    /// intermediate bytes are no evidence either way, so they do not exempt a sequence. The run
    /// is dropped whole rather than repaired, since nothing tells us which characters were the
    /// value's.
    ///
    /// What does exempt a sequence is being one a terminal actually writes around a value —
    /// `sgr0` emits `ESC[m` and `ESC(B` against the value with no space between. Without that
    /// exemption a version or path beside ordinary styling becomes a marker. But `m`, `B`, and
    /// `0` are all characters a value is made of, so both exemptions hold only at the edge of a
    /// run. Between two run characters the terminator may be the value's own: `AB12-ESC(BD34`
    /// strips to the same near-complete `AB12-D34` as an unexempted splice, and a JWT whose JOSE
    /// header loses one character to `ESC[` in front of its own `m` no longer decodes, so the
    /// structural rule that would have removed the whole token stops recognizing it. At either
    /// edge of a run the exemption still holds: the character a sequence could have taken there
    /// is the run's first or last, and every rule whose match a lost character would defeat —
    /// the JOSE header — is anchored on a `e` no SGR and no designation can end on.
    ///
    /// A control string is judged on its own evidence and has its own rule; the two are applied
    /// one after the other because neither is a special case of the other.
    static func redactEscapeSplicedRuns(_ text: String) -> String {
        text.replacing(patterns.escapeSplicedRun, with: marker("spliced-escape"))
            .replacing(patterns.controlStringSplicedRun, with: marker("spliced-escape"))
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
        /// Any CSI or other escape sequence, with the whole run of non-space characters around
        /// it, unless it is an SGR or a charset designation: the final byte of everything else
        /// may be a character of that run rather than the sequence's own. The second alternative
        /// takes both exemptions back where they cannot hold: `m`, `B`, and `0` are characters a
        /// device code and a Base64URL segment are made of, so one standing between two run
        /// characters may be the value's, and the run goes. A sequence at either edge of a run —
        /// where `sgr0` and a terminal's opening reset put one — keeps the exemption, because
        /// what it could have taken there is the run's first or last character, and no rule a
        /// lost character defeats begins on `m`, `B`, or `0`.
        ///
        let escapeSplicedRun = #/\S*(?!(?:\u{1B}\[|\u{9B})[0-9;:]*m|\u{1B}[()*+][B0])(?:(?:\u{1B}\[|\u{9B})[0-9;:?<=>]*[ -\/]*[@-~]|\u{1B}(?![\[\]P_^X])[ -\/]*[0-~])\S*|\S*[A-Za-z0-9_-](?:\u{1B}[()*+][B0]|(?:\u{1B}\[|\u{9B})[0-9;:]*m)[A-Za-z0-9_-]\S*/#
        /// A control string spliced into a run, with the whole run around it.
        ///
        /// Its own rule rather than another alternative above, because it is judged on different
        /// evidence. A control string cannot borrow its terminator from the value — BEL and ST
        /// are characters no credential is made of — but its payload runs to a terminator the
        /// *sender* chooses, so it swallows whatever span the sender points it at, and the rule
        /// above deliberately steps around the introducers (`ESC ]`, `ESC P`, and their C1
        /// spellings) that `terminalEscape` then consumes. That left this splice wide open:
        /// `AB12<ESC>]<BEL>CD34` stripped to `AB12CD34`, a whole device code missing only its
        /// separator, which no pattern below recognizes.
        ///
        /// The introducer has to stand between two characters of a run. At the edge of one it is
        /// the window-title sequence a terminal really writes, and the payload can only have
        /// taken text outside the run, so the version beside it is left alone. The payload is
        /// matched atomically and its terminator is required, so the character after the
        /// sequence is really the run's and cannot be found by giving payload back.
        let controlStringSplicedRun = #/\S*[A-Za-z0-9_-](?:\u{1B}[\]P_^X]|[\u{9D}\u{90}\u{9F}\u{9E}\u{98}])(?>[^\u{07}\u{9C}\u{1B}]*(?:\u{07}|\u{9C}|\u{1B}\\))[A-Za-z0-9_-]\S*/#
        /// A folded header: the label alone on a line, value on the next. Both delimiters the
        /// label rule below accepts count, since `Authorization=` on a line of its own leaves
        /// its value on the next line exactly as `Authorization:` does.
        let authorizationLabelOnly = #/\s*(?:\\?["'])?authorization(?:\\?["'])?\s*[:=]\s*/#.ignoresCase()
        /// Any authorization label, for lines whose value may continue on the next line.
        let authorizationLabel = #/(?:^|[^A-Za-z0-9])authorization\b(?:\\?["'])?\s*[:=]/#.ignoresCase()
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
        let authorizationHeader = #/(^|[^A-Za-z0-9])(?:\\?["'])?authorization\b(?:\\?["'])?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\r\n]*)/#.ignoresCase()
        /// Bearer credentials outside a header line, of any length. Every token and label rule
        /// here starts at a character that cannot be part of the word rather than at `\b`:
        /// Swift's word boundary is the Unicode one, where the dot in `<token>.partial`, in
        /// `cache.<token>`, or in `payload.Authorization` is not a break, and a secret beside
        /// one would survive. The character is captured so it can be put back. A label may also
        /// start after an underscore, which names most of them: `refresh_token`, `access_token`.
        let bearer = #/(^|[^A-Za-z0-9_])(bearer\s+[A-Za-z0-9._~+\/=-]+)/#.ignoresCase()
        /// The word with nothing after it. A reader that cuts an over-long line cuts it at the
        /// last separator, which for `Bearer <token>` is the space between the two, so this is
        /// what the first record ends with and the whole credential is in the tail.
        let bearerLabelOnly = #/(^|[^A-Za-z0-9_])bearer\s*$/#.ignoresCase()
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
        let labeledSecret = #/(^|[^A-Za-z0-9])(?:\\?["'])?((?:(?:access|refresh|auth|client|app|session|user|bearer|private|shared|signing|master|id)[ _-]?)?(?:password|passphrase|passwd|secret|token|api[_-]?key))\b(?:\\?["'])?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S[^\r\n]*)/#.ignoresCase()
        /// The same labels with nothing after the delimiter: CLI and pretty-printed output puts
        /// the value on the next line.
        let secretLabelOnly = #/(^|[^A-Za-z0-9])(?:\\?["'])?((?:(?:access|refresh|auth|client|app|session|user|bearer|private|shared|signing|master|id)[ _-]?)?(?:password|passphrase|passwd|secret|token|api[_-]?key))\b(?:\\?["'])?\s*[:=]\s*$/#.ignoresCase()
        /// The same secret named as a command-line option, which CLI diagnostics echo back
        /// verbatim: `--password hunter2`, `--github-token opaqueCredential`. There is no `:`
        /// or `=` to key on, so the leading dash is what makes this a secret rather than the
        /// word `token` in a sentence. The value is one argv word, or a quoted one, rather than
        /// the rest of the line: an echoed command line carries the options after it, and
        /// `--token abc --verbose` must keep its second option.
        let secretOption = #/(^|\s)(--?[A-Za-z0-9-]*(?:password|passphrase|passwd|secret|token|api[_-]?key))(\s+)(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)/#.ignoresCase()
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
        /// imperative one, which asks for the code, and the declarative one, `Your one-time code
        /// is ABC123`, which names the same codes the delimited rule above knows and states them
        /// instead of asking. The declarative form has to carry a copula, so a line that merely
        /// mentions such a code is not a prompt. The value has to look like a code rather than
        /// like the next English word: four or more characters that are all upper-case or
        /// digits, or that carry a digit. `process exited with code 1`, `Enter the code shown
        /// below`, and `the login code was rejected` are all left alone. The words are matched
        /// without regard to case; the value's own alternatives are not, or every lower-case
        /// word after the label would be a code.
        let codePromptWithoutDelimiter = #/((?:^|[^A-Za-z0-9])(?:(?i:(?:enter|type|paste|copy|input)(?:\s+\S+){0,3}?\s+codes?)|(?i:(?:one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device)[ _-]?codes?(?:\s+(?:is|are|was|were|reads|equals))+)))\s+(?=[A-Za-z0-9._-]{4})(?:[A-Z0-9._-]+|[A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]*)(?![A-Za-z0-9._-])/#
    }

    private static let patterns = Patterns()

    private static func applyPatterns(to input: String, codeExpected: Bool, state: inout StreamState) -> String {
        let p = patterns
        var text = input
        text = text.replacing(p.authorizationHeader) { match in "\(match.1)Authorization: \(marker("authorization"))" }
        // Each token rule captures the character in front of the token, which is put back.
        //
        // A bearer credential is cut like any other value: the token may run to the end of what
        // was scanned, and the word may be all that is left of the record in front of it. Both
        // halves remember that the value continues, because a bearer token is opaque and no
        // rule below would recognize the rest of one on its shape alone.
        var runningValue: StreamState.ContinuedValue?
        let beforeBearer = text
        text = beforeBearer.replacing(p.bearer) { match in
            if match.range.upperBound == beforeBearer.endIndex { runningValue = .secret }
            return "\(match.1)Bearer \(marker("bearer-token"))"
        }
        if text.contains(p.bearerLabelOnly) { runningValue = .secret }
        // The GitHub rule captures nothing in front of the token: it needs no boundary there.
        text = text.replacing(p.githubToken, with: marker("github-token"))
        text = text.replacing(p.apiKey) { match in "\(match.1)\(marker("api-key"))" }
        text = text.replacing(p.jwt) { match in "\(match.1)\(redactedJWT(match.2))" }
        text = text.replacing(p.urlUserInfo) { match in "\(match.1)\(marker("userinfo"))@" }
        // A labeled value can be folded onto the next line, so the label arms the continuation
        // state the way an authorization header does. A value that also runs to the end of what
        // was scanned may have been cut short rather than finished, so which kind it was is
        // remembered too: the tail the reader hands over next is removed as the same value.
        var labelCarriedAValue = false
        let beforeSecrets = text
        text = beforeSecrets.replacing(p.labeledSecret) { match in
            labelCarriedAValue = true
            if match.range.upperBound == beforeSecrets.endIndex { runningValue = .secret }
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretContinuation = labelCarriedAValue
        // The option keeps its name and the spacing that followed it, so an echoed command line
        // still reads as one: `--password [redacted:secret] --verbose`.
        text = text.replacing(p.secretOption) { match in "\(match.1)\(match.2)\(match.3)\(marker("secret"))" }
        let beforeCodes = text
        text = beforeCodes.replacing(p.codeField) { match in
            if match.range.upperBound == beforeCodes.endIndex { runningValue = .deviceCode }
            return "\(match.1)\(match.2): \(marker("device-code"))"
        }
        // A prompt's value is as opaque as a field's, and a forced cut can leave part of it in
        // the next record, so both prompt rules remember that the value continues exactly as
        // the field rule above does: nothing below would recognize the tail of `verification
        // code: <opaque>` on its shape alone, and it would go out verbatim.
        let beforePrompts = text
        text = beforePrompts.replacing(p.codePrompt) { match in
            if match.range.upperBound == beforePrompts.endIndex { runningValue = .deviceCode }
            return "\(match.1) \(marker("device-code"))"
        }
        let beforeBarePrompts = text
        text = beforeBarePrompts.replacing(p.codePromptWithoutDelimiter) { match in
            if match.range.upperBound == beforeBarePrompts.endIndex { runningValue = .deviceCode }
            return "\(match.1) \(marker("device-code"))"
        }
        state.continuedValue = runningValue
        var labelAwaitsValue = false
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

    /// Replaces the three segments of every JWT inside a run of dot-separated segments. A dot is
    /// not a word boundary, so the run can begin with a label such as `session.` and can hold two
    /// adjacent tokens; every segment that has two behind it is tried as the JOSE header, and the
    /// segments around the tokens are kept.
    static func redactedJWT(_ candidate: Substring) -> String {
        var segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        var index = segments.startIndex
        while index + 2 < segments.count {
            if let start = joseHeaderStart(segments[index]) {
                let name = segments[index][..<start]
                segments.replaceSubrange(index...(index + 2), with: [name + Substring(marker("jwt"))])
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
