import Foundation
import RegexBuilder

extension Redactor {
    /// A named JOSE parameter identifies an unfinished token at a physical boundary. Ordinary
    /// JSON claims do not arm continuation, nor does a header already inside a complete JWT.
    static func incompleteJWTStartAtLineEnd(in text: String) -> String.Index? {
        guard let run = text.firstMatch(of: #/(?:^|[^A-Za-z0-9_.-])([A-Za-z0-9_.-]+)$/#),
              run.1.contains(".") else { return nil }
        let segments = run.1.split(separator: ".", omittingEmptySubsequences: false)
        var coveredThrough = 0
        for index in segments.indices {
            guard index >= coveredThrough, let start = joseHeaderStart(segments[index]),
                  let header = decodedJOSEHeader(segments[index][start...]),
                  header["alg"] != nil || header["enc"] != nil else { continue }
            let required = header["enc"] == nil ? 3 : 5
            let emptySignature = required == 3 && header["alg"] as? String == "none"
            let available = segments.count - index - (segments.last?.isEmpty == true && !emptySignature ? 1 : 0)
            if available < required { return start }
            coveredThrough = index + required
        }
        return nil
    }

    /// Replaces all three JWS or five JWE segments inside a run of dot-separated segments. A dot is
    /// not a word boundary, so the run can begin with a label such as `session.` and can hold two
    /// adjacent tokens; every segment with at least two following it is tried as a JOSE header, and the
    /// segments around the tokens are kept.
    static func redactedJWT(_ candidate: Substring) -> String {
        var result = ""
        var cursor = candidate.startIndex
        for range in jwtRedactionRanges(candidate) {
            result += range.lowerBound >= cursor ? String(candidate[cursor..<range.lowerBound]) : "."
            result += marker("jwt")
            cursor = max(cursor, range.upperBound)
        }
        return result + candidate[cursor...]
    }

    /// Original spans are shared with terminal recovery so it cannot invent a second JOSE grammar.
    /// Overlapping spans remain separate here; each header still represents a sensitive token.
    static func jwtRedactionRanges(_ candidate: Substring) -> [Range<String.Index>] {
        let segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        var ranges: [Range<String.Index>] = []
        var coveredThrough = segments.startIndex
        for index in segments.indices {
            guard index + 2 < segments.count, let start = joseHeaderStart(segments[index]) else { continue }
            let header = decodedJOSEHeader(segments[index][start...])
            // Claims are also JSON objects. Only a JOSE parameter identifies a competing
            // header within the current token; ordinary claims keep their original span.
            guard index >= coveredThrough || header?["alg"] != nil || header?["enc"] != nil else { continue }
            let count = header?["enc"] == nil ? 3 : 5
            // Never expose a filename prefix or segment already covered by an earlier token.
            // Overlapping headers extend that coverage, even if the later token is shorter.
            ranges.append(start..<segments[min(index + count, segments.endIndex) - 1].endIndex)
            coveredThrough = max(coveredThrough, min(index + count, segments.endIndex))
        }
        return ranges
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
    static func jsonObjectSuffixStart(_ bytes: [UInt8]) -> Int? {
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

    static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Whether a Base64URL segment decodes to a JOSE header object.
    static func isJOSEHeader(_ segment: Substring) -> Bool {
        joseSegmentCount(segment) != nil
    }

    /// The required JWE "enc" parameter distinguishes five-segment encrypted tokens from JWS.
    static func joseSegmentCount(_ segment: Substring) -> Int? {
        guard let header = decodedJOSEHeader(segment) else { return nil }
        return header["enc"] == nil ? 3 : 5
    }

    private static func decodedJOSEHeader(_ segment: Substring) -> [String: Any]? {
        guard let data = decodedBase64URL(segment) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func decodedBase64URL(_ segment: Substring) -> Data? {
        var base64 = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
