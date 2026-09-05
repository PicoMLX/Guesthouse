import Foundation
import RegexBuilder

extension Redactor {
    /// Redacts a complete text that may contain multiple lines.
    func redact(_ text: String) -> String {
        redact(text, codesAlwaysRedacted: false)
    }

    /// Redacts text that reached the app from somewhere else — decoded from JSON, received over
    /// XPC — where the surrounding context that makes a bare device code recognizable is gone.
    /// Device codes are therefore removed unconditionally, as in `redact(fieldValue:)`.
    func redact(untrusted text: String) -> String {
        redact(text, codesAlwaysRedacted: true)
    }

    /// Redacts one line of a stream. Pass the same `state` for every line of one stream.
    func redact(line: String, state: inout StreamState) -> RedactedLine {
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
        let tokenAtLineEnd = stripped.joined.firstMatch(of: Self.patterns.wrappedTokenAtLineEnd)
            .map { $0.1.hasPrefix("sk-") ? "api-key" : "github-token" }
        if let kind = state.wrappedTokenKind, !text.allSatisfy(\.isWhitespace) {
            state.wrappedTokenKind = nil
            if let continuation = text.firstMatch(of: Self.patterns.tokenContinuation) {
                let fragment = String(continuation.0)
                state.wrappedTokenKind = continuation.range.upperBound == text.endIndex ? kind : nil
                // Detect and retain every ordinary redaction BEFORE masking the continuation.
                // Otherwise replacing `password` first destroys the evidence that its value
                // must be removed. Future state alone cannot protect this line's value.
                var originalScan = StreamState()
                let sanitized = redact(line: text, state: &originalScan).text
                Self.mergePendingContexts(from: originalScan, into: &boundaryScan)
                text = sanitized.hasPrefix(fragment)
                    ? Self.marker(kind) + sanitized.dropFirst(fragment.count)
                    : sanitized
            }
        }
        defer {
            state.wrappedTokenKind = tokenAtLineEnd ?? state.wrappedTokenKind
            Self.mergePendingContexts(from: boundaryScan, into: &state)
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
    func redact(fieldValue: String) -> String {
        redact(untrusted: fieldValue)
    }

    /// Convenience for a batch of lines from one stream.
    func redact(lines: [String]) -> [RedactedLine] {
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
}
