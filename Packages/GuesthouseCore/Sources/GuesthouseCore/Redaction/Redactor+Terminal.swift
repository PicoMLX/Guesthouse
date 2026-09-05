import Foundation
import RegexBuilder

extension Redactor {
    /// Removes terminal control sequences: CSI in both encodings, OSC/DCS/APC/PM/SOS strings
    /// with their payloads, escape sequences with or without intermediate bytes, and bare C0/C1
    /// controls. Tabs and line terminators retain their framing role; other controls are removed
    /// before secret matching so a backspace or styling sequence cannot interrupt a credential.
    static func stripTerminalEscapes(_ text: String) -> String {
        renderings(of: text).joined
    }

    /// The same, for one line of a stream: a control string may open on one line and terminate
    /// on a later one, and everything in between is its payload, not text to scan. Dropping that
    /// payload here also keeps the terminator from joining the words on either side of it.
    static func stripTerminalEscapes(
        _ line: String,
        openControlString: inout StreamState.ControlString?
    ) -> (joined: String, spliced: String, contexts: [String]) {
        var text = line
        if let open = openControlString {
            let end = open == .osc ? patterns.oscEnd : patterns.controlStringEnd
            guard let terminator = text.firstMatch(of: end) else { return ("", "", []) }
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

    private typealias RecoveredCredential = (range: Range<Int>, kind: String)

    /// Boundary-free spans protect token interiors; recognition still requires each rule's
    /// usual leading boundary unless an actual removed control supplied one at that position.
    private static func terminalCredentialSpans(in text: String) -> [(range: Range<String.Index>, kind: String, needsBoundary: Bool)] {
        var spans = text.matches(of: patterns.githubToken).map { ($0.range, "github-token", false) }
        spans += text.matches(of: #/sk-[A-Za-z0-9_-]{16,}/#).map { ($0.range, "api-key", true) }
        spans += text.matches(of: patterns.distinctiveAPIKey).map { ($0.range, "api-key", false) }
        spans += text.matches(of: #/bearer\s+[A-Za-z0-9._~+\/=-]+/#.ignoresCase()).map { ($0.range, "bearer-token", true) }
        spans += text.matches(of: patterns.basicCredentialSpan).compactMap { match in
            isBasicCredential(match.2) ? (match.range, "authorization", true) : nil
        }
        spans += text.matches(of: patterns.digestCredentialSpan).map { ($0.range, "authorization", true) }
        spans += text.matches(of: patterns.specializedCredentialSpan).map { ($0.range, "authorization", true) }
        spans += text.matches(of: patterns.jwt).flatMap { jwtRedactionRanges($0.2).map { ($0, "jwt", false) } }
        spans += text.matches(of: patterns.urlUserInfo).map { ($0.1.endIndex..<$0.range.upperBound, "userinfo", false) }
        return spans
    }

    /// Recover command finals as scan-only evidence, never as visible output. Token ranges
    /// can be masked here; opaque field contexts need the caller's quote/private-key state.
    private static func recoveredCredentialRanges(in text: String, joined: String)
        -> (ranges: [RecoveredCredential], contexts: [String]) {
        var recovered: [RecoveredCredential] = []
        var contexts: [String] = []
        let ordinary = terminalCredentialSpans(in: joined).map { span -> RecoveredCredential in
            let lower = joined.utf8.distance(from: joined.utf8.startIndex, to: span.range.lowerBound)
            let upper = joined.utf8.distance(from: joined.utf8.startIndex, to: span.range.upperBound)
            return (lower..<upper, span.kind)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let escapes = text.matches(of: patterns.terminalEscape)
        for retainParameters in [false, true] {
            var alternate = ""
            var offsets = [0]
            var retained: [Range<Int>] = []
            var boundaries: Set<Int> = []
            var joinedCount = 0
            var cursor = text.startIndex
            func appendLiteral(_ literal: Substring) {
                alternate += literal
                for _ in literal.utf8 { joinedCount += 1; offsets.append(joinedCount) }
            }
            for escape in escapes {
                appendLiteral(text[cursor..<escape.range.lowerBound])
                boundaries.insert(offsets.count - 1)
                let prefix = escape.0.hasPrefix("\u{1B}[") ? 2 : (escape.0.hasPrefix("\u{009B}") ? 1 : 0)
                // CAN/SUB or a fresh ESC abort the old CSI; its parameters are not evidence.
                if prefix > 0, let final = escape.0.unicodeScalars.last, !(0x40...0x7E).contains(final.value) {
                    cursor = escape.range.upperBound
                    continue
                }
                // Generic ESC commands can consume a label character too. Never interpret
                // an OSC/DCS/APC/PM/SOS payload as a generic command's final byte.
                let generic = escape.0.wholeMatch(of: #/\u{1B}(?![\[\]P_^X])[ -\/]*[0-~]/#) != nil
                let body = String(generic ? escape.0.suffix(1) : escape.0.dropFirst(prefix))
                    .replacing(#/[\u{00}-\u{1F}\u{7F}]/#, with: "")
                if prefix > 0 || generic, !body.isEmpty, retainParameters || body.count == 1 {
                    let start = offsets.count - 1
                    alternate += body
                    offsets.append(contentsOf: repeatElement(joinedCount, count: body.utf8.count))
                    retained.append(start..<(offsets.count - 1))
                }
                cursor = escape.range.upperBound
            }
            guard !retained.isEmpty else { continue }
            appendLiteral(text[cursor...])
            // A restored label can identify an opaque value with no recognizable token shape.
            let fields = alternate.matches(of: patterns.labeledSecret).map { ($0.range, $0.3.startIndex) }
                + alternate.matches(of: patterns.authorizationHeader).map { ($0.range, $0.2.startIndex) }
                + alternate.matches(of: patterns.codeField).map { ($0.range, $0.3.startIndex) }
            for (range, valueStart) in fields {
                let lower = alternate.utf8.distance(from: alternate.startIndex, to: range.lowerBound)
                let labelEnd = alternate.utf8.distance(from: alternate.startIndex, to: valueStart)
                if retained.contains(where: { $0.overlaps(lower..<labelEnd) }) {
                    contexts.append(alternate)
                    break
                }
            }
            let recognizedStarts = Set(
                alternate.matches(of: patterns.apiKey).map { $0.2.startIndex }
                + alternate.matches(of: patterns.bearer).map { $0.2.startIndex }
                + alternate.matches(of: patterns.basicAuthorization).map { $0.2.startIndex }
                + alternate.matches(of: patterns.digestAuthorization).map { $0.1.endIndex }
                + alternate.matches(of: patterns.specializedAuthorization).map { $0.1.endIndex }
            )
            var retainedIndex = 0
            var ordinaryIndex = 0
            var coveredEnds: [String: Int] = [:]
            for span in terminalCredentialSpans(in: alternate).sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                let lower = alternate.utf8.distance(from: alternate.utf8.startIndex, to: span.range.lowerBound)
                let upper = alternate.utf8.distance(from: alternate.utf8.startIndex, to: span.range.upperBound)
                guard !span.needsBoundary || boundaries.contains(lower) || recognizedStarts.contains(span.range.lowerBound) else { continue }
                while retainedIndex < retained.count, retained[retainedIndex].upperBound <= lower { retainedIndex += 1 }
                if offsets[lower] < offsets[upper], retainedIndex < retained.count, retained[retainedIndex].lowerBound < upper {
                    while ordinaryIndex < ordinary.count, ordinary[ordinaryIndex].range.lowerBound <= offsets[lower] {
                        let known = ordinary[ordinaryIndex]
                        coveredEnds[known.kind] = max(coveredEnds[known.kind] ?? 0, known.range.upperBound)
                        ordinaryIndex += 1
                    }
                    // Preserve the normal renderer and its labels when it already recognizes
                    // the whole projected credential. Only additional coverage needs a marker.
                    if span.kind != "jwt", (coveredEnds[span.kind] ?? 0) >= offsets[upper] { continue }
                    recovered.append((offsets[lower]..<offsets[upper], span.kind))
                }
            }
        }
        var merged: [RecoveredCredential] = []
        for span in recovered.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = merged.last, span.range.lowerBound <= last.range.upperBound {
                merged[merged.count - 1] = (last.range.lowerBound..<max(last.range.upperBound, span.range.upperBound), last.kind)
            } else { merged.append(span) }
        }
        return (merged, contexts)
    }

    /// Inserting a marker must never hide evidence of a larger credential recognized in the
    /// ordinary reading (for example a five-segment JWE or a longer Bearer value).
    private static func expandingRecoveredRanges(_ recovered: [RecoveredCredential], through ordinary: [Range<Int>]) -> [RecoveredCredential] {
        let spans = (recovered.map { (range: $0.range, kind: Optional($0.kind)) } + ordinary.map { (range: $0, kind: nil as String?) })
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        var clusters: [(range: Range<Int>, kind: String?)] = []
        for span in spans {
            if let last = clusters.last, span.range.lowerBound < last.range.upperBound {
                clusters[clusters.count - 1] = (last.range.lowerBound..<max(last.range.upperBound, span.range.upperBound),
                                                last.kind ?? span.kind)
            } else { clusters.append(span) }
        }
        return clusters.compactMap { span in span.kind.map { (span.range, $0) } }
    }

    /// Joined text repairs interrupted labels; spliced text preserves control-supplied token
    /// boundaries and conceals recovered token spans. Scan-only contexts retain restored field
    /// evidence for the state-aware caller. Ordinary lines have identical visible readings.
    static func renderings(of text: String) -> (joined: String, spliced: String, contexts: [String]) {
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
        let recovery = recoveredCredentialRanges(in: text, joined: joined)
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
                guard suffix.prefixMatch(of: patterns.labeledSecret) != nil
                    || suffix.prefixMatch(of: patterns.secretLabelOnly) != nil
                    || suffix.prefixMatch(of: patterns.authorizationHeader) != nil
                    || suffix.prefixMatch(of: patterns.codeField) != nil
                    || suffix.prefixMatch(of: patterns.secretOption) != nil
                    || suffix.prefixMatch(of: patterns.secretOptionOnly) != nil else { continue }
                // The token may have swallowed a separate label. Keep that label available
                // to the stream scanner, but conceal even a now-short token prefix.
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
