import Foundation
import RegexBuilder

extension Redactor {
    /// Pretty-printed values may start after an empty label or an opening quote on its own.
    /// A completed empty string is already a value and must not consume the following line.
    /// An odd trailing backslash explicitly continues the value onto the next line.
    static func valueStartsOnNextLine(_ value: Substring) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "", "\"", "'", "\\\"", "\\'": return true
        default: return valueExplicitlyContinues(value[...])
        }
    }

    static func valueExplicitlyContinues(_ value: Substring) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2)
    }

    static func isBasicCredential(_ value: Substring) -> Bool {
        decodedBase64URL(value)?.contains(0x3A) == true
    }

    static func unterminatedQuote(in value: Substring, kind: String) -> StreamState.QuotedValue? {
        let value = value.drop(while: { $0.isWhitespace })
        let slashes = value.prefix(while: { $0 == "\\" }).count
        let afterSlashes = value.dropFirst(slashes)
        guard let delimiter = afterSlashes.first, delimiter == "\"" || delimiter == "'" else { return nil }
        let quoted = StreamState.QuotedValue(delimiter: delimiter, escapeDepth: slashes, kind: kind)
        return closingQuoteEnd(in: afterSlashes.dropFirst(), for: quoted) == nil ? quoted : nil
    }

    static func closingQuoteEnd(in value: Substring, for quoted: StreamState.QuotedValue) -> String.Index? {
        var slashes = 0
        for index in value.indices {
            let character = value[index]
            if character == "\\" {
                slashes += 1
                continue
            }
            if character == quoted.delimiter,
               quoted.singleQuotesAreLiteral || quoteCloses(depth: quoted.escapeDepth, slashes: slashes) {
                return value.index(after: index)
            }
            slashes = 0
        }
        return nil
    }

    private static func quoteCloses(depth: Int, slashes: Int) -> Bool {
        // Encoded delimiters can follow any even number of backslashes, each expanded
        // by the surrounding encoding layer. Serialized single quotes also use escapes.
        slashes >= depth && (slashes - depth).isMultiple(of: 2 * (depth + 1))
    }

    /// Scan argument boundaries before replacing them. Plain shell quotes, quotes escaped by
    /// a surrounding diagnostic string, and escaped whitespace all belong to the same value.
    static func redactSecretOptions(_ text: String, state: inout StreamState) -> String {
        var result = ""
        var cursor = text.startIndex
        while let match = text[cursor...].firstMatch(of: patterns.secretOption) {
            result += text[cursor..<match.range.lowerBound]
            // A missing value must not consume a later option's name and leave that option's
            // value unlabelled. Only a recognized secret option is left for another scan:
            // an opaque password beginning with a dash must still be removed.
            let remainder = text[match.range.upperBound...]
            let bareOption = remainder.prefixMatch(of: patterns.secretOptionOnly) != nil
            if match.3 != "=", bareOption || remainder.prefixMatch(of: patterns.secretOption) != nil {
                result += match.0
                cursor = match.range.upperBound
                state.expectingSecretValue = state.expectingSecretValue || bareOption
                continue
            }
            let argument = secretArgument(in: text, from: match.range.upperBound)
            state.quotedValue = state.quotedValue ?? argument.quoted
            state.expectingSecretValue = state.expectingSecretValue || argument.continuesLine
            state.secretValueExplicitlyContinues = state.secretValueExplicitlyContinues || argument.continuesLine
            // Canonicalize equals to a space so the generic field rule cannot treat the
            // replacement and later arguments as a single unquoted passphrase.
            let separator = match.3 == "=" ? " " : String(match.3)
            result += "\(match.1)\(match.2)\(separator)\(marker("secret"))"
            cursor = argument.end
        }
        return result + text[cursor...]
    }

    static func secretArgument(in text: String, from start: String.Index) -> (end: String.Index, quoted: StreamState.QuotedValue?, continuesLine: Bool) {
        var cursor = start
        var quote: Character?
        var quoteEscapeDepth = 0
        var continuesLine = false
        while cursor < text.endIndex {
            if quote == nil, text[cursor].isWhitespace { return (cursor, nil, false) }
            let escapeStart = cursor
            var escapeDepth = 0
            while cursor < text.endIndex, text[cursor] == "\\" {
                escapeDepth += 1
                text.formIndex(after: &cursor)
            }
            guard cursor < text.endIndex else {
                continuesLine = !escapeDepth.isMultiple(of: 2)
                break
            }
            if let delimiter = quote {
                // Unlike serialized diagnostic strings, shell single quotes have no escapes.
                let closesQuote = (delimiter == "'" && quoteEscapeDepth == 0)
                    || quoteCloses(depth: quoteEscapeDepth, slashes: escapeDepth)
                if text[cursor] == delimiter, closesQuote {
                    quote = nil
                }
            } else if text[cursor] == "\"" || text[cursor] == "'" {
                if escapeStart == start || escapeDepth.isMultiple(of: 2) {
                    quote = text[cursor]
                    // An encoded diagnostic quote can open at the beginning. Within a shell
                    // word, an odd backslash count escapes the quote as a literal character.
                    quoteEscapeDepth = escapeStart == start ? escapeDepth : 0
                }
            } else if text[cursor].isWhitespace, escapeDepth.isMultiple(of: 2) {
                return (cursor, nil, false)
            }
            text.formIndex(after: &cursor)
        }
        return (text.endIndex, quote.map {
            .init(delimiter: $0, escapeDepth: quoteEscapeDepth, kind: "secret",
                  singleQuotesAreLiteral: $0 == "'" && quoteEscapeDepth == 0)
        }, continuesLine)
    }

    static func redactSerializedOptions(_ text: String, state: inout StreamState) -> String {
        var result = ""
        var cursor = text.startIndex
        while let match = text[cursor...].firstMatch(of: patterns.serializedSecretOption) {
            result += text[cursor..<match.range.upperBound]
            let value = text[match.range.upperBound...]
            // Do not consume a second secret option as a missing first option's value.
            if value.prefixMatch(of: patterns.serializedSecretOption) != nil {
                cursor = value.startIndex
                continue
            }
            guard !value.isEmpty else {
                state.expectingSecretValue = true
                return result
            }
            let slashes = value.prefix(while: { $0 == "\\" }).count
            let afterSlashes = value.dropFirst(slashes)
            if let delimiter = afterSlashes.first, delimiter == "\"" || delimiter == "'" {
                let quoted = StreamState.QuotedValue(delimiter: delimiter, escapeDepth: slashes, kind: "secret")
                if let end = closingQuoteEnd(in: afterSlashes.dropFirst(), for: quoted) {
                    cursor = end
                } else {
                    state.quotedValue = state.quotedValue ?? quoted
                    cursor = text.endIndex
                }
            } else {
                cursor = value.firstIndex(where: { $0 == "," || $0 == "]" }) ?? text.endIndex
            }
            if fieldExplicitlyContinues(value[..<cursor], tail: text[cursor...]) {
                state.expectingSecretValue = true
                state.secretValueExplicitlyContinues = true
            }
            result += marker("secret")
        }
        return result + text[cursor...]
    }
}
