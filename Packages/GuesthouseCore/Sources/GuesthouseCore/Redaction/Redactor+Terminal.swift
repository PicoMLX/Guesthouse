import Foundation
import RegexBuilder

extension Redactor {
    /// Removes terminal control sequences: CSI in both encodings, OSC/DCS/APC/PM/SOS strings
    /// with their payloads, escape sequences with or without intermediate bytes, and bare C0/C1
    /// controls. Tabs and line terminators retain their framing role; other controls are removed
    /// before secret matching so a backspace or styling sequence cannot interrupt a credential.
    static func stripTerminalEscapes(_ text: String) -> String {
        var pending: TerminalControlGrammar.Pending?
        var result = ""
        var cursor = text.startIndex
        // Payload may span records, but their CR/LF framing is not payload to discard.
        for separator in text.matches(of: patterns.lineSeparator) {
            let record = TerminalControlGrammar.prepare(String(text[cursor..<separator.range.lowerBound]), pending: &pending)
            result += TerminalControlGrammar.normalize(record) + separator.0
            cursor = separator.range.upperBound
        }
        return result + TerminalControlGrammar.normalize(TerminalControlGrammar.prepare(String(text[cursor...]), pending: &pending))
    }

    /// The same, for one line of a stream: a control string may open on one line and terminate
    /// on a later one, and everything in between is its payload, not text to scan. Dropping that
    /// payload here also keeps the terminator from joining the words on either side of it.
    static func stripTerminalEscapes(
        _ line: String,
        openControlString: inout StreamState.ControlString?
    ) -> (joined: String, spliced: String, contexts: [String]) {
        let prepared = TerminalControlEvidence.prepare(line, continuation: &openControlString)
        return renderings(of: prepared.text, priorPrefixes: prepared.prefixes)
    }

    /// Stands where an escape did, in the `spliced` reading only. It has to be a boundary to
    /// every token rule and removable without consuming the remaining diagnostic. Unit
    /// Separator is a bare control, never a control-string introducer.
    static let splicedBoundary = "\u{001F}"

    private typealias RecoveredCredential = (range: Range<Int>, kind: String)


    /// Joined text repairs interrupted labels; spliced text preserves control-supplied token
    /// boundaries and conceals recovered token spans. Scan-only contexts retain restored field
    /// evidence for the state-aware caller. Ordinary lines have identical visible readings.
    static func renderings(of text: String, priorPrefixes: [String] = []) -> (joined: String, spliced: String, contexts: [String]) {
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
            if boundaryOffsets.last != joinedByteCount {
                boundaryOffsets.append(joinedByteCount)
            }
            scanned = escape.range.upperBound
        }
        joined += text[scanned...]
        // Adjacent controls share one offset. Inspect surviving neighbors only after every
        // escape is removed, so a neighboring control cannot hide a credential's boundary.
        boundaryOffsets = boundaryOffsets.filter { offset in
            let boundary = joined.utf8.index(joined.utf8.startIndex, offsetBy: offset)
            let suffix = joined[boundary...]
            return (joined[..<boundary].last.map(isTokenCharacter) == true
                && suffix.first.map(isTokenCharacter) == true)
                || suffix.prefixMatch(of: #/(?:\\*\/){2}/#) != nil
        }
        let recovery = recoveredCredentialRanges(in: text, joined: joined, priorPrefixes: priorPrefixes)
        var recovered = recovery.ranges
        guard !boundaryOffsets.isEmpty || !recovered.isEmpty else { return (joined, joined, recovery.contexts) }

        // A boundary inside a recognized token would let the first scan redact only a valid
        // prefix. Closing the boundary afterwards cannot recover the remaining suffix. Keep
        // recognized tokens whole in both readings, while retaining boundaries before tokens
        // that need them, such as `filename<control>sk-...`.
        let tokenRanges = terminalCredentialSpans(in: joined).map(\.range)
        func byteRange(_ range: Range<String.Index>) -> Range<Int> {
            let lower = joined.utf8.distance(from: joined.utf8.startIndex, to: range.lowerBound)
            let upper = joined.utf8.distance(from: joined.utf8.startIndex, to: range.upperBound)
            return lower..<upper
        }
        var ordinaryRanges = tokenRanges
        // A JOSE segment can spell a field/prompt name. Its marker must not hide that name
        // while leaving the independently recognized value outside the recovered token.
        ordinaryRanges += joined.matches(of: patterns.authorizationHeader).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.labeledSecret).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.codeField).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.codePrompt).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.codePromptWithoutDelimiter).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.declarativeCodePrompt).map(\.range)
        // A recovered segment can also contain the BEGIN word. Protect the current PEM body
        // before replacing it; the stream scanner separately retains its normalized state.
        ordinaryRanges += joined.matches(of: patterns.pemBegin).map { begin in
            let tail = joined[begin.range.upperBound...]
            let end = tail.range(of: "-----END \(begin.1)-----")?.upperBound ?? joined.endIndex
            return begin.range.lowerBound..<end
        }
        recovered = expandingRecoveredRanges(recovered, through: ordinaryRanges.map(byteRange))
        let byteRanges = (tokenRanges.map(byteRange) + recovered.map(\.range)).sorted { $0.lowerBound < $1.lowerBound }
        var mergedRanges: [Range<Int>] = []
        for range in byteRanges {
            if let last = mergedRanges.last, range.lowerBound < last.upperBound {
                mergedRanges[mergedRanges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                mergedRanges.append(range)
            }
        }
        var spliced = ""
        var insertedOffsets: [Int] = []
        var rangeIndex = 0
        scanned = joined.startIndex
        for offset in boundaryOffsets {
            while rangeIndex < mergedRanges.count, mergedRanges[rangeIndex].upperBound <= offset {
                rangeIndex += 1
            }
            if rangeIndex < mergedRanges.count, mergedRanges[rangeIndex].lowerBound < offset {
                let boundary = joined.utf8.index(joined.utf8.startIndex, offsetBy: offset)
                let suffix = joined[boundary...]
                guard terminalHasCredentialOpener(suffix) else { continue }
                // The token may have swallowed a separate label. Keep that label available
                // to the stream scanner, but conceal even a now-short token prefix.
                // A recovered token can cross this boundary too. Its speculative suffix
                // must not erase the independently recognized next credential's opener.
                recovered = recovered.map { span in
                    span.range.lowerBound < offset && offset < span.range.upperBound
                        ? (span.range.lowerBound..<offset, span.kind) : span
                }
                recovered.append((mergedRanges[rangeIndex].lowerBound..<offset, "secret"))
            }
            let boundary = joined.utf8.index(joined.utf8.startIndex, offsetBy: offset)
            spliced += joined[scanned..<boundary]
            spliced += splicedBoundary
            insertedOffsets.append(offset)
            scanned = boundary
        }
        spliced += joined[scanned...]
        var mapped: [RecoveredCredential] = []
        var insertedIndex = 0
        for span in expandingRecoveredRanges(recovered, through: []) {
            let range = span.range
            while insertedIndex < insertedOffsets.count, insertedOffsets[insertedIndex] <= range.lowerBound { insertedIndex += 1 }
            let lower = range.lowerBound + insertedIndex * splicedBoundary.utf8.count
            while insertedIndex < insertedOffsets.count, insertedOffsets[insertedIndex] < range.upperBound { insertedIndex += 1 }
            mapped.append((lower..<(range.upperBound + insertedIndex * splicedBoundary.utf8.count), span.kind))
        }
        var redacted = ""
        scanned = spliced.startIndex
        for span in mapped {
            let range = span.range
            let lower = spliced.utf8.index(spliced.utf8.startIndex, offsetBy: range.lowerBound)
            let upper = spliced.utf8.index(spliced.utf8.startIndex, offsetBy: range.upperBound)
            redacted += spliced[scanned..<lower]
            redacted += marker(span.kind)
            scanned = upper
        }
        return (joined, redacted + spliced[scanned...], recovery.contexts)
    }
}
