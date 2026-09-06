import Foundation

extension Redactor {
    /// Boundary-free spans protect token interiors; recognition still requires each rule's
    /// usual leading boundary unless an actual removed control supplied one at that position.
    static func terminalCredentialSpans(in text: String) -> [(range: Range<String.Index>, kind: String, needsBoundary: Bool)] {
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
        if text.contains(patterns.mentionsCode) {
            spans += text.matches(of: patterns.deviceCode).map { ($0.2.startIndex..<$0.2.endIndex, "device-code", false) }
        }
        return spans
    }


    /// Inserting a marker must never hide evidence of a larger credential recognized in the
    /// ordinary reading (for example a five-segment JWE or a longer Bearer value).
    static func expandingRecoveredRanges(_ recovered: [(range: Range<Int>, kind: String)], through ordinary: [Range<Int>]) -> [(range: Range<Int>, kind: String)] {
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
}
