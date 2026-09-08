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
        let strings = closedDiagnosticStringRanges(in: input)
        var stringIndex = strings.startIndex
        return input.replacing(#/((?:^|[^A-Za-z0-9\\:=])\s*)(\\*)("(?:(?!\\*"\s*[:=])(?:[^"\\]|\\.))*\\*"|"(?:(?!\\*"\s*[:=])(?:[^"'\\:=]|\\.))*\\*|'(?:(?!\\*'\s*[:=])(?:[^'\\]|\\.))*\\*'|'(?:(?!\\*'\s*[:=])(?:[^'"\\:=]|\\.))*\\*)(?=\s*[:=]|[ \t]*$)/#) { match in
            guard match.3.contains("\\") else { return String(match.0) }
            // Whitespace after an assignment introduces its value, not another key.
            if match.1.allSatisfy(\.isWhitespace),
               input[..<match.range.lowerBound].last(where: { !$0.isWhitespace }).map({ ":=".contains($0) }) == true {
                return String(match.0)
            }
            let quote = String(match.3.prefix(1))
            let keyStart = match.3.startIndex
            let content = match.3.dropFirst().dropLast(match.3.hasSuffix(quote) ? 1 : 0)
            if content.contains(#/^--[^"' \t]+\\*["'][ \t]*,/#) { return String(match.0) }
            // Both scans visit monotonically increasing ranges. Advance each string
            // at most once instead of rescanning every earlier value for every field.
            while stringIndex < strings.endIndex, strings[stringIndex].upperBound <= keyStart {
                strings.formIndex(after: &stringIndex)
            }
            // A brace/comma inside a serialized value is not an outer field boundary.
            if stringIndex < strings.endIndex {
                let range = strings[stringIndex]
                if (range.lowerBound < keyStart && range.contains(keyStart))
                    || (range.lowerBound == keyStart && range.upperBound > match.range.upperBound
                        && content.contains(where: { "\"'".contains($0) })) {
                    return String(match.0)
                }
            }
            let framing = String(match.2)
            var encoded = String(match.3)
            func key(_ name: String) -> String { String(match.1) + framing + quote + name + framing + quote }
            if !encoded.hasSuffix(quote), input[match.range.upperBound...].allSatisfy(\.isWhitespace) {
                state.pendingEncodedCredentialKey = true
            }
            // The framing backslashes are transport quoting, not part of the JSON name.
            if !framing.isEmpty, encoded.hasSuffix(framing + quote) {
                encoded = String(encoded.dropLast(framing.count + 1)) + quote
            }
            // Single-quoted diagnostics share JSON's Unicode escapes. Normalize only
            // the bounded name; unsupported/malformed quoting still fails closed.
            guard encoded.utf8.prefix(1025).count <= 1024 else { return key("secret") }
            if quote == "'" {
                guard encoded.hasSuffix("'") else { return key("secret") }
                encoded = "\"" + encoded.dropFirst().dropLast().replacingOccurrences(of: "\\'", with: "'")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
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

    /// One pass, including when every quote is transport-escaped. A regex looking
    /// for a closing quote would retry every unclosed opener against the whole suffix.
    private static func closedDiagnosticStringRanges(in input: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var opener: String.Index?
        var delimiter: Character = "\""
        var escaped = false
        for index in input.indices {
            let character = input[index]
            if !escaped {
                if let start = opener {
                    if character == delimiter {
                        ranges.append(start..<input.index(after: index))
                        opener = nil
                    }
                } else if character == "\"" || character == "'" {
                    opener = index
                    delimiter = character
                }
            }
            escaped = character == "\\" ? !escaped : false
        }
        return ranges
    }
}
