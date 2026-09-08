import Foundation

extension Redactor {
    /// A decoded JOSE parameter identifies an incomplete compact token at a record boundary.
    static func incompleteJWTStartAtLineEnd(in text: String) -> String.Index? {
        guard let run = text.firstMatch(of: #/(?:^|[^A-Za-z0-9_.-])([A-Za-z0-9_.-]+)(?=[ \t]*$)/#) else { return nil }
        let segments = run.1.split(separator: ".", omittingEmptySubsequences: false)
        for index in segments.indices {
            guard let start = joseHeaderStart(segments[index]),
                  let header = decodedJOSEHeader(segments[index][start...]),
                  header["alg"] != nil || header["enc"] != nil else { continue }
            let required = header["enc"] == nil ? 3 : 5
            let emptySignature = required == 3 && header["alg"] as? String == "none"
            let available = segments.count - index - (segments.last?.isEmpty == true && !emptySignature ? 1 : 0)
            if available < required { return start }
        }
        return nil
    }

    /// Quoted and ordinary records both advance footer-to-next-opener state.
    static func redactPEMBlocks(_ input: String, label: inout String?) -> String {
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
}
