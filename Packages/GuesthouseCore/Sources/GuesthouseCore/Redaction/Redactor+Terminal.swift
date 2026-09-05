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

    /// A CSI introducer inserted into a token can consume its next character as the command's
    /// final byte. Keep two bounded alternate readings: parameterless CSI bodies, and all CSI
    /// bodies. The first also works beside ordinary parameterized styling in the same token.
    /// Control-string payloads remain suppressed in both. Only recognized JOSE spans are mapped
    /// back; none of the retained command bytes themselves can reappear in the rendered output.
    private static func recoveredJWTRanges(in text: String) -> [Range<Int>] {
        var recovered: [Range<Int>] = []
        let escapes = text.matches(of: patterns.terminalEscape)
        for retainParameters in [false, true] {
            var alternate = ""
            var offsets = [0]
            var retained: [Range<Int>] = []
            var joinedCount = 0
            var cursor = text.startIndex
            func appendLiteral(_ literal: Substring) {
                alternate += literal
                for _ in literal.utf8 { joinedCount += 1; offsets.append(joinedCount) }
            }
            for escape in escapes {
                appendLiteral(text[cursor..<escape.range.lowerBound])
                let prefix = escape.0.hasPrefix("\u{1B}[") ? 2 : (escape.0.hasPrefix("\u{009B}") ? 1 : 0)
                let body = escape.0.dropFirst(prefix)
                if prefix > 0, !body.isEmpty, retainParameters || body.count == 1 {
                    let start = offsets.count - 1
                    alternate += body
                    offsets.append(contentsOf: repeatElement(joinedCount, count: body.utf8.count))
                    retained.append(start..<(offsets.count - 1))
                }
                cursor = escape.range.upperBound
            }
            guard !retained.isEmpty else { continue }
            appendLiteral(text[cursor...])
            var retainedIndex = 0
            for match in alternate.matches(of: patterns.jwt) {
                for range in jwtRedactionRanges(match.2) {
                    let lower = alternate.utf8.distance(from: alternate.utf8.startIndex, to: range.lowerBound)
                    let upper = alternate.utf8.distance(from: alternate.utf8.startIndex, to: range.upperBound)
                    while retainedIndex < retained.count, retained[retainedIndex].upperBound <= lower { retainedIndex += 1 }
                    if offsets[lower] < offsets[upper], retainedIndex < retained.count, retained[retainedIndex].lowerBound < upper {
                        recovered.append(offsets[lower]..<offsets[upper])
                    }
                }
            }
        }
        var merged: [Range<Int>] = []
        for range in recovered.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }

    /// Inserting a marker must never hide evidence of a larger credential recognized in the
    /// ordinary reading (for example a five-segment JWE or a longer Bearer value).
    private static func expandingRecoveredRanges(_ recovered: [Range<Int>], through ordinary: [Range<Int>]) -> [Range<Int>] {
        let spans = (recovered.map { (range: $0, recovered: true) } + ordinary.map { (range: $0, recovered: false) })
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        var clusters: [(range: Range<Int>, recovered: Bool)] = []
        for span in spans {
            if let last = clusters.last, span.range.lowerBound < last.range.upperBound {
                clusters[clusters.count - 1] = (last.range.lowerBound..<max(last.range.upperBound, span.range.upperBound),
                                                last.recovered || span.recovered)
            } else { clusters.append(span) }
        }
        return clusters.filter(\.recovered).map(\.range)
    }

    /// The two readings of a line whose terminal escapes have been removed: `joined`, where the
    /// text on either side of an escape closes up, and `spliced`, where an escape that stood
    /// between two characters a token can contain leaves a boundary behind. Only the second one
    /// shows where a token begins when styling was put in front of it; only the first one keeps
    /// a label that styling interrupted spelled correctly. `spliced` is `joined` when no escape
    /// stood in such a place, which is every ordinary line. The spliced reading also masks JOSE
    /// spans recovered before a CSI final byte could destroy their recognizable header.
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
            return joined[..<boundary].last.map(isTokenCharacter) == true
                && joined[boundary...].first.map(isTokenCharacter) == true
        }
        var recovered = recoveredJWTRanges(in: text)
        guard !boundaryOffsets.isEmpty || !recovered.isEmpty else { return (joined, joined) }

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
        func byteRange(_ range: Range<String.Index>) -> Range<Int> {
            let lower = joined.utf8.distance(from: joined.utf8.startIndex, to: range.lowerBound)
            let upper = joined.utf8.distance(from: joined.utf8.startIndex, to: range.upperBound)
            return lower..<upper
        }
        var ordinaryRanges = tokenRanges + joined.matches(of: patterns.jwt).flatMap { jwtRedactionRanges($0.2) }
        // A JOSE segment can spell a field/prompt name. Its marker must not hide that name
        // while leaving the independently recognized value outside the recovered token.
        ordinaryRanges += joined.matches(of: patterns.authorizationHeader).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.labeledSecret).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.codeField).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.codePrompt).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.codePromptWithoutDelimiter).map(\.range)
        ordinaryRanges += joined.matches(of: patterns.declarativeCodePrompt).map(\.range)
        recovered = expandingRecoveredRanges(recovered, through: ordinaryRanges.map(byteRange))
        tokenRanges += joined.matches(of: patterns.jwt).compactMap { match in
            redactedJWT(match.2) == String(match.2) ? nil : match.range
        }
        let byteRanges = (tokenRanges.map(byteRange) + recovered).sorted { $0.lowerBound < $1.lowerBound }
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
                continue
            }
            let boundary = joined.utf8.index(joined.utf8.startIndex, offsetBy: offset)
            spliced += joined[scanned..<boundary]
            spliced += splicedBoundary
            insertedOffsets.append(offset)
            scanned = boundary
        }
        spliced += joined[scanned...]
        var mapped: [Range<Int>] = []
        var insertedIndex = 0
        for range in recovered {
            while insertedIndex < insertedOffsets.count, insertedOffsets[insertedIndex] <= range.lowerBound { insertedIndex += 1 }
            let lower = range.lowerBound + insertedIndex * splicedBoundary.utf8.count
            while insertedIndex < insertedOffsets.count, insertedOffsets[insertedIndex] < range.upperBound { insertedIndex += 1 }
            mapped.append(lower..<(range.upperBound + insertedIndex * splicedBoundary.utf8.count))
        }
        var redacted = ""
        scanned = spliced.startIndex
        for range in mapped {
            let lower = spliced.utf8.index(spliced.utf8.startIndex, offsetBy: range.lowerBound)
            let upper = spliced.utf8.index(spliced.utf8.startIndex, offsetBy: range.upperBound)
            redacted += spliced[scanned..<lower]
            redacted += marker("jwt")
            scanned = upper
        }
        return (joined, redacted + spliced[scanned...])
    }
}
