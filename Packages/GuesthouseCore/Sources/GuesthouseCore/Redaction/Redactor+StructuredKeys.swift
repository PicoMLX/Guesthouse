import Foundation

extension Redactor {
    /// Canonicalize encoded credential names only at structural field boundaries.
    /// Unknown valid names keep their spelling; malformed/oversized names fail closed.
    /// Decode at most 1024 bytes and never retain decoded names or value bytes in state.
    static func normalizingStructuredCredentialKeys(in input: String) -> String {
        var state = StreamState()
        return normalizingStructuredCredentialKeys(in: input, state: &state)
    }

    static func normalizingStructuredCredentialKeys(in input: String, state: inout StreamState) -> String {
        if state.pendingEncodedCredentialKey {
            // Discard arbitrary key fragments without retaining bytes. Once an
            // assignment arrives, the existing secret-value scanner owns its tail.
            guard let delimiter = input.firstIndex(where: { $0 == ":" || $0 == "=" }) else { return marker("encoded-key") }
            state.pendingEncodedCredentialKey = false
            return "\"secret\":" + input[input.index(after: delimiter)...]
        }
        let strings = input.matches(of: #/"(?:[^"\\]|\\.)*"/#)
        var stringIndex = strings.startIndex
        return input.replacing(#/((?:^|[{\[,])\s*)(\\*)("(?:(?!\\*"\s*[:=])(?:[^"\\]|\\.))*\\*"|"(?:(?!\\*"\s*[:=])(?:[^"\\:=]|\\.))*\\*)(?=\s*[:=]|[ \t]*$)/#) { match in
            guard match.3.contains("\\") else { return String(match.0) }
            // Both scans visit monotonically increasing ranges. Advance each string
            // at most once instead of rescanning every earlier value for every field.
            while stringIndex < strings.endIndex, strings[stringIndex].range.upperBound <= match.range.lowerBound {
                strings.formIndex(after: &stringIndex)
            }
            // A brace/comma inside a serialized value is not an outer field boundary.
            if stringIndex < strings.endIndex {
                let range = strings[stringIndex].range
                if (range.lowerBound < match.range.lowerBound && range.contains(match.range.lowerBound))
                    || (range.lowerBound == match.range.lowerBound && range.upperBound > match.range.upperBound) {
                    return String(match.0)
                }
            }
            let framing = String(match.2)
            var encoded = String(match.3)
            func key(_ name: String) -> String { String(match.1) + framing + "\"" + name + framing + "\"" }
            if encoded.last != "\"", input[match.range.upperBound...].allSatisfy(\.isWhitespace) {
                state.pendingEncodedCredentialKey = true
            }
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
