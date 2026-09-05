import Foundation
import RegexBuilder

extension Redactor {
    /// Decode only quoting/backslash escapes, not control escapes such as `\n`: physical
    /// line framing belongs to the stream parser. Each call strictly reduces escape depth.
    static func removingQuotedEncodingLayer(_ value: String) -> String {
        var result = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let character = value[cursor]
            value.formIndex(after: &cursor)
            if character == "\\", cursor < value.endIndex, "\\\"'".contains(value[cursor]) {
                result.append(value[cursor])
                value.formIndex(after: &cursor)
            } else { result.append(character) }
        }
        return result
    }

    /// A completely decoded string has its own argument boundary. Only remove a wrapper
    /// whose first matching closing quote is the end, never a quote plus sibling suffix.
    static func unwrappingCompleteDecodedString(_ value: String) -> String {
        guard let quote = value.first, quote == "\"" || quote == "'",
              closingQuoteEnd(in: value.dropFirst(),
                  for: .init(delimiter: quote, escapeDepth: 0, kind: "secret")) == value.endIndex
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    struct ProtectedQuotedValues {
        var text: String
        var values: [String: String] = [:]
        var contexts: [String: StreamState] = [:]

        func restoring(in text: String, state: inout StreamState) -> String {
            text.replacing(Self.placeholder) { match in
                let key = String(match.1)
                if let context = contexts[key] { mergePendingContexts(from: context, into: &state) }
                return values[key] ?? String(match.0)
            }
        }

        static var placeholder: Regex<(Substring, Substring)> { #/"\u{E001}([0-9]+)\u{E002}"/# }
    }

    /// Preserve encoded non-secret values while giving the field rules ordinary bounded quotes.
    /// Each closed value is scanned once; field siblings never recurse over a remaining suffix.
    static func protectEncodedQuotedValues(in input: String, sanitize: (String) -> (String, StreamState)) -> ProtectedQuotedValues {
        let reserved = Set(input.matches(of: ProtectedQuotedValues.placeholder).map { String($0.1) })
        var result = ProtectedQuotedValues(text: "")
        var cursor = input.startIndex
        var copied = cursor
        var identifier = 0
        while let opener = input[cursor...].firstMatch(of: #/(\\+)(["'])/#) {
            guard let quote = opener.2.first,
                  let end = closingQuoteEnd(in: input[opener.range.upperBound...],
                      for: .init(delimiter: quote, escapeDepth: opener.1.count, kind: "secret")) else { break }
            cursor = end
            let tail = input[end...].drop(while: { $0.isWhitespace })
            // A colon/equal means this is a key, not a value. Undelimited suffixes can still
            // belong to a shell/diagnostic credential and must stay in the unquoted rule.
            // Closing delimiters from outer encodings can precede the structural boundary.
            // An arbitrary suffix (including another quoted word) is still ambiguous.
            let structuralTail = tail.drop(while: { "\"'".contains($0) }).drop(while: { $0.isWhitespace })
            guard structuralTail.isEmpty || structuralTail.first.map({ ",;]}".contains($0) }) == true else { continue }
            let content = input[opener.range.upperBound..<end].dropLast(opener.1.count + 1)
            let previous = input[..<opener.range.lowerBound].last(where: { !$0.isWhitespace })
            // Preserve argv adjacency in the parent scan: hiding an option name behind a
            // placeholder would detach the following value. Canonicalize only known names
            // at an array-element boundary, not arbitrary diagnostic strings.
            if previous == "[" || previous == ",",
               tail.first == ",", !content.contains("="),
               content.wholeMatch(of: patterns.secretOptionOnly) != nil {
                result.text += input[copied..<opener.range.lowerBound] + "\"" + content + "\""
                copied = end
                continue
            }
            while reserved.contains(String(identifier)) { identifier += 1 }
            let key = String(identifier)
            identifier += 1
            result.text += input[copied..<opener.range.lowerBound]
            result.text += "\"\u{E001}\(key)\u{E002}\""
            let sanitized = sanitize(String(input[opener.range.lowerBound..<end]))
            result.values[key] = sanitized.0
            result.contexts[key] = sanitized.1
            copied = end
        }
        result.text += input[copied...]
        return result
    }

    static func isClosedQuotedValue(_ value: Substring) -> Bool { closedQuotedValueTail(value) != nil }

    /// A raw quote ends a regex capture before an explicit physical-line continuation.
    /// Only whitespace/backslashes may follow it; a sibling field owns its own suffix.
    static func fieldExplicitlyContinues(_ value: Substring, tail: Substring) -> Bool {
        valueExplicitlyContinues(value) || (isClosedQuotedValue(value)
            && tail.allSatisfy({ $0.isWhitespace || $0 == "\\" }) && valueExplicitlyContinues(tail))
    }

    static func closedQuotedValueTail(_ value: Substring) -> Substring? {
        let start = value.drop(while: { $0.isWhitespace })
        let depth = start.prefix(while: { $0 == "\\" }).count
        let content = start.dropFirst(depth)
        guard let quote = content.first, quote == "\"" || quote == "'",
              let end = closingQuoteEnd(in: content.dropFirst(), for: .init(delimiter: quote, escapeDepth: depth, kind: "secret"))
        else { return nil }
        let tail = value[end...]
        let suffix = tail.drop(while: { $0.isWhitespace })
        guard suffix.isEmpty || suffix.allSatisfy({ $0 == "\\" })
                || suffix.first.map({ ",;]}".contains($0) }) == true else { return nil }
        return tail
    }
}
