import Foundation
import RegexBuilder

extension Redactor {
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
    static func renderings(of text: String) -> (joined: String, spliced: String) {
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
        tokenRanges += joined.matches(of: patterns.distinctiveAPIKey).map(\.range)
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
}
