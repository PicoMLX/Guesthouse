import Foundation

extension Redactor {
    /// Canonicalize encoded credential names only at structural field boundaries.
    /// Unknown valid names keep their spelling; malformed/oversized names fail closed.
    /// Decode at most 1024 bytes and never retain decoded names or value bytes in state.
    static func normalizingStructuredCredentialKeys(in input: String) -> String {
        let strings = input.matches(of: #/"(?:[^"\\]|\\.)*"/#)
        return input.replacing(#/((?:^|[{\[,])\s*)(\\*)("(?:[^"]|"(?!\s*[:=]))*"|"(?:[^":=]|"(?!\s*[:=]))*)(?=\s*[:=]|[ \t]*$)/#) { match in
            // A brace/comma inside a serialized value is not an outer field boundary.
            guard !strings.contains(where: { $0.range.lowerBound < match.range.lowerBound && $0.range.contains(match.range.lowerBound) }) else { return String(match.0) }
            let framing = String(match.2)
            var encoded = String(match.3)
            func key(_ name: String) -> String { String(match.1) + framing + "\"" + name + framing + "\"" }
            guard encoded.contains("\\") else { return String(match.0) }
            // The framing backslashes are transport quoting, not part of the JSON name.
            if !framing.isEmpty, encoded.hasSuffix(framing + "\"") {
                encoded = String(encoded.dropLast(framing.count + 1)) + "\""
            }
            guard encoded.utf8.prefix(1025).count <= 1024,
                  let name = try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))
            else { return key("secret") }
            let label = name + ":"
            guard label.wholeMatch(of: patterns.secretLabelOnly) != nil
                || label.wholeMatch(of: patterns.authorizationHeader) != nil
                || label.wholeMatch(of: patterns.codePromptOnly) != nil
            else { return String(match.0) }
            let safeName = name.first?.isWhitespace != true && name.last?.isWhitespace != true && name.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || " ._-".contains($0))
            } ? name : "secret"
            return key(safeName)
        }
    }
}
