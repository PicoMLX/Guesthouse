import Foundation

extension Redactor {
    /// A flat diagnostic list can contain one bracket pair inside an IPv6 host literal.
    private static var URLDiagnosticList: Regex<Substring> {
        #/\[(?:[^\[\]\r\n]|\[[^\[\]\r\n]*\])*\]/#
    }
    /// RFC 8259 strings can encode URL delimiters as Unicode escapes. Decode only a
    /// bounded, closed string, scan once, and re-encode only when it contains userinfo.
    /// No decoded payload is retained in stream state or emitted without sanitization.
    private static func redactEncodedURLStrings(_ input: String, state: inout StreamState) -> String {
        var text = input
        if state.pendingEncodedURLString {
            var escaped = state.encodedURLHasTrailingEscape
            var closing: String.Index?
            for index in text.indices {
                let character = text[index]
                if character == "\"" && !escaped { closing = index; break }
                escaped = character == "\\" ? !escaped : false
            }
            state.encodedURLHasTrailingEscape = escaped
            guard let closing else { return marker("encoded-value") }
            state.pendingEncodedURLString = false
            state.encodedURLHasTrailingEscape = false
            text = marker("encoded-value") + text[text.index(after: closing)...]
        }
        text = text.replacing(#/"(?:[^"\\\r\n]|\\[^\r\n])*"/#) { match in
            let encoded = match.0
            guard encoded.contains(#"\u"#) else { return String(encoded) }
            guard encoded.utf8.prefix(8193).count <= 8192,
                  let decoded = try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))
            else { return "\"" + marker("encoded-value") + "\"" }
            guard decoded.contains(patterns.urlUserInfo) else { return String(encoded) }
            var context = StreamState()
            let sanitized = redactURLContinuations(decoded, state: &context, decodeStrings: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            guard let data = try? encoder.encode(sanitized) else { return "\"" + marker("userinfo") + "\"" }
            return String(decoding: data, as: UTF8.self)
        }
        // A Unicode escape can hide every authority delimiter. Until this quoted
        // URL closes, emit a marker per record and retain only escape parity.
        if let partial = text.firstMatch(of: #/"(?:[^"\\\r\n]|\\[^\r\n])*\\?$/#),
           partial.0.contains(#"\u"#),
           partial.0.contains(#/[A-Za-z][A-Za-z0-9+.-]*(?::|\\u003[aA])|\\u002[fF]/#) {
            state.pendingEncodedURLString = true
            state.encodedURLHasTrailingEscape = !partial.0.reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2)
            text = String(text[..<partial.range.lowerBound]) + marker("encoded-value")
        }
        return text
    }

    /// An EOL authority may be userinfo whose @ arrives later; emitted bytes cannot be
    /// retracted. A path/query/fragment or proven diagnostic frame ends the authority.
    static func redactURLContinuations(_ input: String, state: inout StreamState, decodeStrings: Bool = true) -> String {
        let input = decodeStrings ? redactEncodedURLStrings(input, state: &state) : input
        defer {
            if !input.allSatisfy(\.isWhitespace) {
                state.urlHasTrailingEscape = state.expectingURLUserInfo
                    && !input.reversed().drop(while: \.isWhitespace).prefix(while: { $0 == "\\" }).count.isMultiple(of: 2)
            }
        }
        // A comma separates URLs only when the next element starts another authority.
        // Otherwise it may be part of the current URI's userinfo (or path/query).
        // A comma + authority is ambiguous even inside a query. Conceal its userinfo
        // rather than assuming that a nested URL or compact list element is public.
        func sanitized(_ element: Substring) -> String {
            String(element).replacing(patterns.urlUserInfo) { "\($0.1)\(marker("userinfo"))@" }
        }
        var cursor = input.startIndex
        var text = ""
        for separator in input.matches(of: #/,(?=[ \t]*(?:(?:--?)?[A-Za-z][A-Za-z0-9_.-]*[ \t]*=[ \t]*)?(?:[A-Za-z][A-Za-z0-9+.-]*:)?(?:\\*\/){2})/#) {
            text += sanitized(input[cursor..<separator.range.lowerBound]) + ","
            cursor = separator.range.upperBound
        }
        text += sanitized(input[cursor...])
        if state.pendingURLSlashes > 0 {
            var remaining = state.pendingURLSlashes
            state.pendingURLSlashes = 0
            var cursor = text.drop(while: \.isWhitespace).startIndex
            while remaining > 0 {
                while cursor < text.endIndex, text[cursor] == "\\" { text.formIndex(after: &cursor) }
                guard cursor < text.endIndex else { state.pendingURLSlashes = remaining; return text }
                guard text[cursor] == "/" else { break }
                text.formIndex(after: &cursor)
                remaining -= 1
            }
            if remaining == 0 {
                state.expectingURLUserInfo = true
                return String(text[..<cursor]) + redactURLContinuations(String(text[cursor...]), state: &state, decodeStrings: decodeStrings)
            }
        }
        if state.expectingURLUserInfo {
            let value = text.drop(while: \.isWhitespace)
            guard !value.isEmpty else { return text }
            let frameClosers = ">]}\"`"
            var escaped = state.urlHasTrailingEscape
            var end = value.startIndex
            while end < text.endIndex {
                let character = text[end]
                let escapedQuote = character == "\"" && escaped
                if !escapedQuote && (character.isWhitespace || "/?#".contains(character) || frameClosers.contains(character)) { break }
                escaped = character == "\\" ? !escaped : false
                text.formIndex(after: &end)
            }
            let at = text[value.startIndex..<end].lastIndex(of: "@")
            // Every @ may belong to the password until the authority is structurally closed.
            // Do not expose a provisional host suffix while another record can extend it.
            state.expectingURLUserInfo = end == text.endIndex
            let stop = state.expectingURLUserInfo ? end : (at ?? end)
            // A non-userinfo frame closer also bounds a host-only continuation.
            // Apostrophes/parentheses remain possible password bytes, not closers.
            if at != nil || end == text.endIndex {
                text = String(text[..<value.startIndex]) + marker("userinfo") + text[stop...]
            }
        }
        if let partial = text.firstMatch(of: patterns.partialURLAuthority) {
            state.pendingURLSlashes = partial.0.reversed().drop(while: { $0 == "\\" }).first == "/" ? 1 : 2
        }
        return text.replacing(patterns.incompleteURLUserInfo) { match in
            if hasCompleteURLFrame(in: text, prefixEnd: match.1.endIndex) { return String(match.0) }
            state.expectingURLUserInfo = true
            return String(match.1) + marker("userinfo")
        }
    }

    /// Only framing outside URI userinfo's grammar can prove same-record closure.
    /// Parentheses/apostrophes are valid sub-delimiters even when they appear paired.
    private static func hasCompleteURLFrame(in text: String, prefixEnd: String.Index) -> Bool {
        var start = prefixEnd
        while start > text.startIndex, text[..<start].last.map({ "/\\".contains($0) }) == true {
            text.formIndex(before: &start)
        }
        if text[..<start].last == ":" {
            text.formIndex(before: &start)
            while start > text.startIndex, text[..<start].last.map({
                $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0))
            }) == true { text.formIndex(before: &start) }
        }
        if let assignment = text[..<start].firstMatch(of: #/(?:--?)?[A-Za-z][A-Za-z0-9_.-]*[ \t]*=[ \t]*$/#) {
            start = assignment.range.lowerBound
        }
        // The URL can be the final element of a flat diagnostic list, or part of
        // prose inside one whole-record double-quoted value. Neither frame belongs
        // to URI userinfo; escaped or missing closing quotes are not proof of closure.
        if text.matches(of: URLDiagnosticList).contains(where: {
            $0.range.lowerBound < start && prefixEnd < $0.range.upperBound
        }) { return true }
        // A continued list may have lost its opener on a preceding record. A comma
        // authority boundary plus the terminal list closer still bounds its last element.
        if text[..<start].last == ",", text[prefixEnd...].last == "]" { return true }
        let quotedRecord = text.drop(while: \.isWhitespace)
        if quotedRecord.first == "\"", quotedRecord.startIndex < start,
           let end = closingQuoteEnd(in: quotedRecord.dropFirst(),
               for: .init(delimiter: "\"", escapeDepth: 0, kind: "userinfo")),
           prefixEnd < end { return true }
        if text[..<start].last == "\"" {
            return closingQuoteEnd(in: text[start...],
                for: .init(delimiter: "\"", escapeDepth: 0, kind: "userinfo")) != nil
        }
        let closers: [Character: Character] = ["<": ">", "{": "}", "`": "`"]
        guard let opener = text[..<start].last, let closer = closers[opener],
              let end = text[start...].firstIndex(of: closer) else { return false }
        let content = text[start..<end]
        return !content.contains(opener) && !content.contains(closer)
    }

}
