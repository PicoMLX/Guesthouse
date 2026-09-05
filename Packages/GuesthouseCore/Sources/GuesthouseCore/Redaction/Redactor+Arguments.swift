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
        let firstValueCharacter = value.firstIndex(where: { !$0.isWhitespace }) ?? value.endIndex
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let start = cursor
            var slashes = 0
            while cursor < value.endIndex, value[cursor] == "\\" {
                slashes += 1
                value.formIndex(after: &cursor)
            }
            guard cursor < value.endIndex else { break }
            let delimiter = value[cursor]
            let predecessor = start == value.startIndex ? nil : value[value.index(before: start)]
            value.formIndex(after: &cursor)
            // Parameters can open quotes after an unquoted scheme or prefix. Apostrophes
            // inside an ordinary word are not delimiters (for example a passphrase's "don't").
            guard delimiter == "\"" || delimiter == "'",
                  predecessor == nil || predecessor?.isWhitespace == true
                    || predecessor.map({ "=:([{,".contains($0) }) == true else { continue }
            let hasPrefix = start > firstValueCharacter
            let quoted = StreamState.QuotedValue(delimiter: delimiter,
                escapeDepth: slashes.isMultiple(of: 2) ? 0 : slashes, kind: kind,
                enclosingAuthorizationFold: hasPrefix && kind == "authorization",
                enclosingSecretFold: hasPrefix && kind == "secret")
            guard let end = closingQuoteEnd(in: value[cursor...], for: quoted) else { return quoted }
            cursor = end
        }
        return nil
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
        var concealOptionName = false
        while let match = text[cursor...].firstMatch(of: patterns.secretOption) {
            result += text[cursor..<match.range.lowerBound]
            // A following secret option could also be this option's opaque value. Conceal
            // its name but retain the original input for scanning its possible value too.
            let optionName = concealOptionName ? marker("secret") : String(match.2)
            concealOptionName = false
            let remainder = text[match.range.upperBound...]
            let bareOption = remainder.prefixMatch(of: patterns.secretOptionOnly) != nil
            if match.3 != "=", bareOption || remainder.prefixMatch(of: patterns.secretOption) != nil {
                result += "\(match.1)\(optionName)\(match.3)"
                if bareOption { result += marker("secret") }
                cursor = bareOption ? text.endIndex : match.range.upperBound
                concealOptionName = true
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
            result += "\(match.1)\(optionName)\(separator)\(marker("secret"))"
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
                    // Even leading slashes are literal shell backslashes before a raw quote;
                    // only an odd depth denotes an escaped diagnostic delimiter.
                    quoteEscapeDepth = escapeStart == start && !escapeDepth.isMultiple(of: 2) ? escapeDepth : 0
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
        var concealOptionName = false
        while let match = text[cursor...].firstMatch(of: patterns.serializedSecretOption) {
            result += text[cursor..<match.range.lowerBound]
            if concealOptionName, let comma = match.0.lastIndex(of: ",") {
                result += marker("secret") + match.0[comma...]
            } else { result += match.0 }
            concealOptionName = false
            let value = text[match.range.upperBound...]
            // Preserve both interpretations of an option-shaped opaque credential.
            if value.prefixMatch(of: patterns.serializedSecretOption) != nil {
                concealOptionName = true
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
            result += marker("secret")
        }
        return result + text[cursor...]
    }
}
