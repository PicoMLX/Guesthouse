import Foundation

extension Redactor {
    typealias TerminalCredentialRange = (range: Range<Int>, kind: String)

    /// Boundary-free span discovery is not proof that the ordinary renderer recognizes it.
    static func terminalRecognizedStarts(in text: String) -> Set<String.Index> {
        Set(text.matches(of: patterns.apiKey).map { $0.2.startIndex }
            + text.matches(of: patterns.bearer).map { $0.2.startIndex }
            + text.matches(of: patterns.basicAuthorization).map { $0.2.startIndex }
            + text.matches(of: patterns.digestAuthorization).map { $0.1.endIndex }
            + text.matches(of: patterns.specializedAuthorization).map { $0.1.endIndex })
    }

    /// Recover command finals as scan-only evidence, never as visible output. Token ranges
    /// can be masked here; opaque field contexts need the caller's quote/private-key state.
    static func recoveredCredentialRanges(in text: String, joined: String, priorPrefixes: [String])
        -> (ranges: [TerminalCredentialRange], contexts: [String]) {
        var recovered: [TerminalCredentialRange] = []
        var contexts: [String] = []
        let ordinaryStarts = terminalRecognizedStarts(in: joined)
        let ordinary = terminalCredentialSpans(in: joined)
            .filter { !$0.needsBoundary || ordinaryStarts.contains($0.range.lowerBound) }
            .map { span -> TerminalCredentialRange in
            let lower = joined.utf8.distance(from: joined.utf8.startIndex, to: span.range.lowerBound)
            let upper = joined.utf8.distance(from: joined.utf8.startIndex, to: span.range.upperBound)
            return (lower..<upper, span.kind)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard let projections = TerminalControlEvidence.projections(in: text, prefixes: priorPrefixes) else {
            return ([(0..<joined.utf8.count, "terminal-ambiguity")], [])
        }
        for projection in projections where !projection.retained.isEmpty {
            let alternate = projection.text
            let offsets = projection.offsets
            let retained = projection.retained
            let boundaries = projection.boundaries
            // Short recognizable prefixes still own a possible next-record continuation.
            if alternate.contains(patterns.wrappedTokenAtLineEnd) && !joined.contains(patterns.wrappedTokenAtLineEnd) {
                contexts.append(alternate)
            }
            // A restored label can identify an opaque value with no recognizable token shape.
            let fields = alternate.matches(of: patterns.labeledSecret).map { ($0.range, $0.3.startIndex) }
                + alternate.matches(of: patterns.authorizationHeader).map { ($0.range, $0.2.startIndex) }
                + alternate.matches(of: patterns.codeField).map { ($0.range, $0.3.startIndex) }
                + alternate.matches(of: patterns.secretOption).map { ($0.range, $0.range.upperBound) }
                + alternate.matches(of: patterns.secretOptionOnly).map { ($0.range, $0.range.upperBound) }
                + alternate.matches(of: patterns.secretLabelOnly).map { ($0.range, $0.range.upperBound) }
                + alternate.matches(of: patterns.serializedSecretOption).map { ($0.range, $0.range.upperBound) }
                + alternate.matches(of: patterns.codePrompt).map { ($0.range, $0.1.endIndex) }
                + alternate.matches(of: patterns.codePromptWithoutDelimiter).map { ($0.range, $0.1.endIndex) }
                + alternate.matches(of: patterns.declarativeCodePrompt).map { ($0.range, $0.1.endIndex) }
                + alternate.matches(of: patterns.codePromptOnly).map { ($0.range, $0.range.upperBound) }
                + alternate.matches(of: patterns.pemBegin).map { ($0.range, $0.range.upperBound) }
            for (range, valueStart) in fields {
                let lower = alternate.utf8.distance(from: alternate.startIndex, to: range.lowerBound)
                let labelEnd = alternate.utf8.distance(from: alternate.startIndex, to: valueStart)
                if retained.contains(where: { $0.overlaps(lower..<labelEnd) }) {
                    contexts.append(alternate)
                    break
                }
            }
            let recognizedStarts = terminalRecognizedStarts(in: alternate)
            // The restored evidence can be the contextual word "code", not the value itself.
            let restoredCodeContext = !joined.contains(patterns.mentionsCode) && alternate.contains(patterns.mentionsCode)
            var retainedIndex = 0
            var ordinaryIndex = 0
            var coveredEnds: [String: Int] = [:]
            // A restored scheme delimiter proves userinfo too; redact only its value range.
            for match in alternate.matches(of: patterns.urlUserInfo) {
                let start = alternate.utf8.distance(from: alternate.startIndex, to: match.range.lowerBound)
                let value = alternate.utf8.distance(from: alternate.startIndex, to: match.1.endIndex)
                let end = alternate.utf8.distance(from: alternate.startIndex, to: match.range.upperBound)
                if retained.contains(where: { $0.overlaps(start..<value) }), offsets[value] < offsets[end] {
                    recovered.append((offsets[value]..<offsets[end], "userinfo"))
                }
            }
            for span in terminalCredentialSpans(in: alternate).sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                let lower = alternate.utf8.distance(from: alternate.utf8.startIndex, to: span.range.lowerBound)
                let upper = alternate.utf8.distance(from: alternate.utf8.startIndex, to: span.range.upperBound)
                guard !span.needsBoundary || boundaries.contains(lower) || recognizedStarts.contains(span.range.lowerBound) else { continue }
                while retainedIndex < retained.count, retained[retainedIndex].upperBound <= lower { retainedIndex += 1 }
                let touchesEvidence = retainedIndex < retained.count && retained[retainedIndex].lowerBound < upper
                let restoredBoundary = span.needsBoundary && (boundaries.contains(lower)
                    || (recognizedStarts.contains(span.range.lowerBound) && retainedIndex > 0
                        && retained[retainedIndex - 1].upperBound == lower))
                if offsets[lower] < offsets[upper], touchesEvidence || restoredBoundary || (span.kind == "device-code" && restoredCodeContext) {
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
        var merged: [TerminalCredentialRange] = []
        for span in recovered.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = merged.last, span.range.lowerBound <= last.range.upperBound {
                merged[merged.count - 1] = (last.range.lowerBound..<max(last.range.upperBound, span.range.upperBound), last.kind)
            } else { merged.append(span) }
        }
        return (merged, contexts)
    }
}
