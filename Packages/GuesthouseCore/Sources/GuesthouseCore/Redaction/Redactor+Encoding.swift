import Foundation
import RegexBuilder

extension Redactor {
    /// Replaces all three JWS or five JWE segments inside a run of dot-separated segments. A dot is
    /// not a word boundary, so the run can begin with a label such as `session.` and can hold two
    /// adjacent tokens; every segment with at least two following it is tried as a JOSE header, and the
    /// segments around the tokens are kept.
    static func redactedJWT(_ candidate: Substring) -> String {
        var segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        var index = segments.startIndex
        while index + 2 < segments.count {
            if let start = joseHeaderStart(segments[index]) {
                let name = segments[index][..<start]
                let count = joseSegmentCount(segments[index][start...]) ?? 3
                // A truncated token is still sensitive; remove all available token segments.
                let end = min(index + count, segments.endIndex)
                segments.replaceSubrange(index..<end, with: [name + Substring(marker("jwt"))])
            }
            index += 1
        }
        return segments.joined(separator: ".")
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
        guard let data = decodedBase64URL(segment),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return header["enc"] == nil ? 3 : 5
    }

    static func decodedBase64URL(_ segment: Substring) -> Data? {
        var base64 = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
