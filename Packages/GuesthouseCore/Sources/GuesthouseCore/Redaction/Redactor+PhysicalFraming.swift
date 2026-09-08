import Foundation

extension Redactor {
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
