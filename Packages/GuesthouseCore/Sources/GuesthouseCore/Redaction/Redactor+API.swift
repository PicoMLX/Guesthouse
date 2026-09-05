import Foundation
import RegexBuilder

extension Redactor {
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

    /// Redacts a record from a stream. Retained or embedded CR/LF terminators are preserved,
    /// with state advanced once per physical line. Pass the same `state` for the whole stream.
    public func redact(line: String, state: inout StreamState) -> RedactedLine {
        RedactedLine(redact(line, codesAlwaysRedacted: false, state: &state))
    }

    private func redact(line: String, state: inout StreamState, isPhysicalLine: Bool,
                        codesAlwaysRedacted: Bool = false) -> RedactedLine {
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
        let stripped = Self.stripTerminalEscapes(line, openControlString: &state.openControlString,
            codesAlwaysRedacted: codesAlwaysRedacted || state.expectingDeviceCode, activeQuote: state.quotedValue)
        var recoveredContexts = StreamState()
        for reading in stripped.contexts + stripped.stateReadings {
            guard state.ppkPhase == .inactive else { continue }
            var start = reading.startIndex
            if let label = state.pemLabel {
                guard let footer = reading.range(of: "-----END \(label)-----") else { continue }
                start = footer.upperBound
            }
            if let quoted = state.quotedValue {
                guard let end = Self.closingQuoteEnd(in: reading[...], for: quoted) else { continue }
                start = max(start, end)
            }
            var scanned = StreamState()
            _ = redact(line: String(reading[start...]), state: &scanned, isPhysicalLine: false)
            Self.mergePendingContexts(from: scanned, into: &recoveredContexts)
        }
        // Only the physical pass advances PPK framing. On its opening line, preserve any
        // enclosing quote/PEM context in both readings before the private-key early return.
        let wasReadingPPK = state.ppkPhase != .inactive
        let ppkLine = !wasReadingPPK
            ? stripped.contexts.first(where: { $0.contains(Self.patterns.ppkBegin) }) ?? stripped.joined : stripped.joined
        if isPhysicalLine, !wasReadingPPK, let opener = ppkLine.firstMatch(of: Self.patterns.ppkBegin) {
            // Contexts that end before this key do not enclose it. Reuse the ordinary closure
            // transitions on that prefix without advancing physical PPK framing a second time.
            _ = redact(line: String(ppkLine[..<opener.range.lowerBound]), state: &state,
                       isPhysicalLine: false, codesAlwaysRedacted: codesAlwaysRedacted)
        }
        if isPhysicalLine, Self.consumePPKLine(ppkLine, phase: &state.ppkPhase) {
            if !wasReadingPPK {
                var joinedContext = StreamState()
                _ = redact(line: stripped.joined, state: &joinedContext, isPhysicalLine: false)
                Self.mergePendingContexts(from: joinedContext, into: &recoveredContexts)
            }
            Self.mergePendingContexts(from: recoveredContexts, into: &state)
            return RedactedLine(Self.marker("private-key"))
        }
        defer { Self.mergePendingContexts(from: recoveredContexts, into: &state) }
        // A restored label can refer to an opaque value with no recognizable token shape.
        // Conservatively hide this line while preserving both ordinary and recovered state.
        func output(_ value: String) -> RedactedLine {
            RedactedLine(stripped.contexts.isEmpty ? value : Self.marker("secret"))
        }
        var text = stripped.joined
        if let quoted = state.quotedValue {
            // This branch masks the whole physical line, but still has to advance the
            // independently active PEM context before returning for the enclosing quote.
            _ = Self.redactPEMBlocks(text, label: &state.pemLabel)
            // Inspect the original normalized text: replacement markers no longer contain the
            // closing delimiter. A closing line is redacted whole, but its suffix can open a new
            // pending field. Blank/styling-only lines do not close the quoted value.
            if !stripped.quoteMayContinue, let end = Self.closingQuoteEnd(in: text[...], for: quoted) {
                let tail = String(text[end...])
                let explicitlyContinues = Self.valueExplicitlyContinues(tail[...])
                // This suffix is still on the same physical line. Scan it independently so
                // it cannot consume a next-line value or terminate the enclosing fold.
                var suffixState = StreamState()
                _ = redact(line: tail, state: &suffixState, isPhysicalLine: false)
                if stripped.spliced != stripped.joined,
                   let alternateEnd = Self.closingQuoteEnd(in: stripped.spliced[...], for: quoted) {
                    var alternateSuffix = StreamState()
                    _ = redact(line: String(stripped.spliced[alternateEnd...]), state: &alternateSuffix, isPhysicalLine: false)
                    Self.mergePendingContexts(from: alternateSuffix, into: &suffixState)
                }
                if quoted.enclosingAuthorizationFold { suffixState.quotedValue?.enclosingAuthorizationFold = true }
                if quoted.enclosingSecretFold { suffixState.quotedValue?.enclosingSecretFold = true }
                state.quotedValue = nil
                state.wrappedTokenKind = suffixState.wrappedTokenKind
                state.expectingSecretValue = explicitlyContinues && (quoted.kind == "secret" || quoted.enclosingSecretFold)
                state.secretValueExplicitlyContinues = state.expectingSecretValue
                state.expectingSecretContinuation = quoted.enclosingSecretFold || state.expectingSecretValue
                state.authorizationValueIsOnTheNextLine = explicitlyContinues && (quoted.kind == "authorization" || quoted.enclosingAuthorizationFold)
                state.authorizationValueExplicitlyContinues = state.authorizationValueIsOnTheNextLine
                state.expectingAuthorizationValue = quoted.enclosingAuthorizationFold || state.authorizationValueIsOnTheNextLine
                state.expectingDeviceCode = explicitlyContinues && quoted.kind == "device-code"
                Self.mergePendingContexts(from: suffixState, into: &state)
            }
            return output(text.isEmpty ? text : Self.marker(quoted.kind))
        }
        // What the boundary rendering armed, kept apart until this line's own pending contexts
        // have been consumed below and unioned in on the way out.
        var boundaryScan = StreamState()
        if stripped.spliced != stripped.joined {
            // Terminal recovery can mask a label inside a token. Retain the original reading's
            // pending contexts before replacing that evidence with a marker.
            // Joined text has no terminal controls, so this scan has no alternate-reading recursion.
            var joinedScan = StreamState()
            _ = redact(line: stripped.joined, state: &joinedScan, isPhysicalLine: false)
            let boundaryText = Self.applyPatterns(to: stripped.spliced, codeExpected: state.expectingDeviceCode, state: &boundaryScan)
            text = (codesAlwaysRedacted ? Self.applyDeviceCodePattern(to: boundaryText) : boundaryText)
                .replacingOccurrences(of: Self.splicedBoundary, with: "")
            Self.mergePendingContexts(from: joinedScan, into: &boundaryScan)
        }
        let incompleteJWT = Self.incompleteJWTStartAtLineEnd(in: stripped.joined) != nil
            || Self.incompleteJWTStartAtLineEnd(in: stripped.spliced) != nil
        let tokenAtLineEnd = incompleteJWT ? "jwt" : (stripped.joined.firstMatch(of: Self.patterns.wrappedTokenAtLineEnd)
            ?? stripped.spliced.firstMatch(of: Self.patterns.wrappedTokenAtLineEnd))
            .map { $0.1.hasPrefix("sk-") ? "api-key" : "github-token" }
        if let kind = state.wrappedTokenKind, !text.allSatisfy(\.isWhitespace) {
            state.wrappedTokenKind = nil
            let continuationPattern = kind == "jwt" ? #/^[ \t]*[A-Za-z0-9_.-]+/# : Self.patterns.tokenContinuation
            if let continuation = text.firstMatch(of: continuationPattern) {
                let fragment = String(continuation.0)
                state.wrappedTokenKind = continuation.range.upperBound == text.endIndex ? kind : nil
                // Detect and retain every ordinary redaction BEFORE masking the continuation.
                // Otherwise replacing `password` first destroys the evidence that its value
                // must be removed. Future state alone cannot protect this line's value.
                var originalScan = StreamState()
                let sanitized = redact(line: text, state: &originalScan, isPhysicalLine: false).text
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
        let authorizationFoldWasEstablished = state.expectingAuthorizationValue
            && (!authorizationWasAwaitingValue || state.authorizationValueExplicitlyContinues)
        let unindentedValue = authorizationWasAwaitingValue
            && (state.authorizationValueExplicitlyContinues || text.firstMatch(of: Self.patterns.headerLabelStart) == nil)
        let authorizationContinuation = state.expectingAuthorizationValue && !blankLine
            && (unindentedValue || text.wholeMatch(of: Self.patterns.foldedContinuation) != nil)
        if !blankLine {
            state.expectingAuthorizationValue = authorizationContinuation
            state.authorizationValueIsOnTheNextLine = false
            state.authorizationValueExplicitlyContinues = false
        }
        // A labeled value folds the same way a header value does, and the second half of a
        // passphrase is as usable as the first.
        let secretFoldWasEstablished = state.expectingSecretContinuation
            && (!state.expectingSecretValue || state.secretValueExplicitlyContinues)
        let secretContinuation = state.expectingSecretContinuation
            && text.wholeMatch(of: Self.patterns.foldedContinuation) != nil
        if !blankLine {
            state.expectingSecretContinuation = secretContinuation
        }
        if let label = state.pemLabel, !text.contains("-----END \(label)-----") {
            return output(Self.marker("private-key"))
        }
        text = Self.redactPEMBlocks(text, label: &state.pemLabel)

        // The continuation's own text is all credential, but a PEM block it opens keeps running
        // over the lines that follow, so the block is detected above before the marker returns.
        // A secret label or a code prompt inside the fold opens a context the *next* line
        // completes, and only a scan arms that, so the rules run here for their state alone.
        let closedValueTail = Self.closedQuotedValueTail(text[...]).map(String.init)
        let valueContinues = Self.valueStartsOnNextLine(text[...])
        let explicitlyContinues = Self.valueExplicitlyContinues(text[...])
        if authorizationContinuation {
            let wholeValueQuote = Self.unterminatedQuote(in: text[...], kind: "authorization")
            state.quotedValue = wholeValueQuote
            state.authorizationValueIsOnTheNextLine = valueContinues
            state.authorizationValueExplicitlyContinues = explicitlyContinues
            state.expectingAuthorizationValue = authorizationFoldWasEstablished || closedValueTail == nil || valueContinues
            Self.armPendingContexts(from: closedValueTail ?? text, state: &state)
            if wholeValueQuote == nil || authorizationFoldWasEstablished {
                state.quotedValue?.enclosingAuthorizationFold = state.expectingAuthorizationValue
            }
            return output(Self.marker("authorization"))
        }
        if secretContinuation {
            let wholeValueQuote = Self.unterminatedQuote(in: text[...], kind: "secret")
            state.quotedValue = wholeValueQuote
            state.expectingSecretValue = valueContinues
            state.secretValueExplicitlyContinues = explicitlyContinues
            state.expectingSecretContinuation = secretFoldWasEstablished || closedValueTail == nil || valueContinues
            Self.armPendingContexts(from: closedValueTail ?? text, state: &state)
            if wholeValueQuote == nil || secretFoldWasEstablished {
                state.quotedValue?.enclosingSecretFold = state.expectingSecretContinuation
            }
            return output(Self.marker("secret"))
        }

        // A blank line carries nothing and keeps the device-code context for the next one.
        if blankLine {
            return output(text)
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
            let wholeValueQuote = Self.unterminatedQuote(in: text[...], kind: kind)
            state.quotedValue = wholeValueQuote
            state.expectingSecretValue = false
            if secretExpected { state.secretValueExplicitlyContinues = false }
            _ = Self.applyPatterns(to: closedValueTail ?? text, codeExpected: false, state: &state)
            // The consumed value may fold onto further indented lines. A lone opening quote
            // still introduces a value rather than satisfying the pending context.
            if secretExpected {
                state.expectingSecretValue = state.expectingSecretValue || valueContinues
                state.secretValueExplicitlyContinues = state.secretValueExplicitlyContinues || explicitlyContinues
                state.expectingSecretContinuation = state.expectingSecretContinuation || secretFoldWasEstablished || closedValueTail == nil || valueContinues
                if wholeValueQuote == nil || secretFoldWasEstablished {
                    state.quotedValue?.enclosingSecretFold = state.expectingSecretContinuation
                }
            } else if valueContinues {
                state.expectingDeviceCode = true
            }
            return output(Self.marker(kind))
        }
        var redacted = Self.applyPatterns(to: text, codeExpected: codeExpected, state: &state)
        if let start = Self.incompleteJWTStartAtLineEnd(in: redacted) {
            redacted.replaceSubrange(start..<redacted.endIndex, with: Self.marker("jwt"))
        }
        state.secretValueExplicitlyContinues = state.expectingSecretValue && explicitlyContinues
        // A different rule may have replaced the JOSE header with its own token marker.
        // Preserve all original incomplete-token evidence, without releasing a partial payload.
        return output(incompleteJWT ? Self.marker("jwt") : redacted)
    }

    /// Quoted and ordinary lines share the same footer-to-next-opener transition. Clearing
    /// one block must not discard a second opener later on the same physical line.
    private static func redactPEMBlocks(_ input: String, label: inout String?) -> String {
        var text = input
        if let active = label {
            guard let footer = text.range(of: "-----END \(active)-----") else { return marker("private-key") }
            label = nil
            text = marker("private-key") + text[footer.upperBound...]
        }
        while let begin = text.firstMatch(of: patterns.pemBegin) {
            let opened = String(begin.1)
            if let end = text[begin.range.upperBound...].range(of: "-----END \(opened)-----") {
                text.replaceSubrange(begin.range.lowerBound..<end.upperBound, with: marker("private-key"))
            } else {
                label = opened
                text.replaceSubrange(begin.range.lowerBound..<text.endIndex, with: marker("private-key"))
                break
            }
        }
        return text
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

    /// Batch decoding owns one stream state and keeps context-free code matching enabled.
    fileprivate func redact(untrustedLines: [String]) -> [RedactedLine] {
        var state = StreamState()
        return untrustedLines.map { line in
            let sanitized = redact(line: line, state: &state, isPhysicalLine: true, codesAlwaysRedacted: true).text
            return RedactedLine(Self.applyDeviceCodePattern(to: sanitized))
        }
    }

    private func redact(_ text: String, codesAlwaysRedacted: Bool) -> String {
        var state = StreamState()
        return redact(text, codesAlwaysRedacted: codesAlwaysRedacted, state: &state)
    }

    private func redact(_ text: String, codesAlwaysRedacted: Bool, state: inout StreamState) -> String {
        var result = ""
        var lineStart = text.startIndex
        func appendRedacted(_ line: Substring) {
            let redacted = redact(line: String(line), state: &state, isPhysicalLine: true,
                                  codesAlwaysRedacted: codesAlwaysRedacted).text
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
        // A retained terminator ends its record; it does not create an additional empty
        // physical record (which would advance counted private-key framing a second time).
        if lineStart < text.endIndex || text.isEmpty { appendRedacted(text[lineStart...]) }
        return result
    }
}

/// A line of text that has passed through `Redactor`.
///
/// Log sinks, the XPC event stream, and diagnostics exports accept only this type, so an
/// unredacted `String` cannot reach them by accident. Construction goes through `Redactor`,
/// a compile-time literal, or the sanitizing decoding boundaries below.
public struct RedactedLine: Hashable, Sendable, CustomStringConvertible {
    public let text: String

    fileprivate init(_ text: String) {
        self.text = text
    }

    /// For fixed messages that contain nothing to redact, such as `"Started"`.
    public init(literal: StaticString) {
        text = literal.description
    }

    public var description: String { text }
}

extension RedactedLine: Codable {
    /// Decoded text is redacted again: a serialized or XPC-provided value is not trusted to
    /// have passed through `Redactor` on the other side. The line that gave a device code its
    /// context did not survive serialization, so codes are redacted unconditionally here.
    /// Independent records do not share stream state. Decode a physical-line transcript as
    /// `RedactedLines`; direct array-element decoding is rejected rather than losing framing.
    public init(from decoder: any Decoder) throws {
        guard !decoder.codingPath.contains(where: { $0.intValue != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Decode physical-line batches as RedactedLines to preserve shared redaction state."))
        }
        text = Redactor().redact(untrusted: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// An encoded batch of physical lines from one stream, sanitized before typed lines escape.
/// Decode transcripts through this type, not by independently decoding each RedactedLine.
public struct RedactedLines: Hashable, Sendable, Codable {
    public let lines: [RedactedLine]

    public enum ValidationError: Error, Sendable { case embeddedLineTerminator }

    /// Constructs an outgoing transcript using one shared stream state. Each entry must be
    /// one physical record; context-free device codes are concealed as on the decoding path.
    public init(redacting raw: [String]) throws {
        guard !raw.contains(where: { $0.contains(Redactor.patterns.lineSeparator) }) else {
            throw ValidationError.embeddedLineTerminator
        }
        lines = Redactor().redact(untrustedLines: raw)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String].self)
        guard !raw.contains(where: { $0.contains(Redactor.patterns.lineSeparator) }) else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "A physical-line batch cannot contain embedded line terminators.")
        }
        try self.init(redacting: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(lines)
    }
}
