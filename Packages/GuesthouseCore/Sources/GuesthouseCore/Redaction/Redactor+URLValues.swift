import Foundation

extension Redactor {
    /// An EOL authority may be userinfo whose @ arrives later; emitted bytes cannot be
    /// retracted. A path/query/fragment or proven diagnostic frame ends the authority.
    static func redactURLContinuations(_ input: String, state: inout StreamState) -> String {
        // A comma separates URLs only when the next element starts another authority.
        // Otherwise it may be part of the current URI's userinfo (or path/query).
        var text = input.replacing(#/\[[^\[\]\r\n]*\]/#) { match in
            let list = match.0.dropFirst().dropLast()
            func sanitized(_ element: Substring) -> String {
                String(element).replacing(patterns.urlUserInfo) { "\($0.1)\(marker("userinfo"))@" }
            }
            var cursor = list.startIndex
            var result = "["
            for separator in list.matches(of: #/,(?=[ \t]*(?:[A-Za-z][A-Za-z0-9+.-]*:)?(?:\\*\/){2})/#) {
                result += sanitized(list[cursor..<separator.range.lowerBound]) + ","
                cursor = separator.range.upperBound
            }
            return result + sanitized(list[cursor...]) + "]"
        }
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
                return String(text[..<cursor]) + redactURLContinuations(String(text[cursor...]), state: &state)
            }
        }
        if state.expectingURLUserInfo {
            let value = text.drop(while: \.isWhitespace)
            guard !value.isEmpty else { return text }
            let end = value.firstIndex(where: { $0.isWhitespace || "/?#".contains($0) }) ?? text.endIndex
            let at = text[value.startIndex..<end].lastIndex(of: "@")
            state.expectingURLUserInfo = at == nil && end == text.endIndex
            let stop = at ?? end
            text = String(text[..<value.startIndex]) + marker("userinfo") + text[stop...]
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
        if text.matches(of: #/\[[^\[\]\r\n]*\]/#).contains(where: {
            $0.range.lowerBound < start && prefixEnd < $0.range.upperBound
        }) { return true }
        let quotedRecord = text.drop(while: \.isWhitespace)
        if quotedRecord.first == "\"", quotedRecord.startIndex < start,
           let end = closingQuoteEnd(in: quotedRecord.dropFirst(),
               for: .init(delimiter: "\"", escapeDepth: 0, kind: "userinfo")),
           prefixEnd < end, text[end...].allSatisfy(\.isWhitespace) { return true }
        if text[..<start].last == "\"" {
            guard let end = closingQuoteEnd(in: text[start...],
                for: .init(delimiter: "\"", escapeDepth: 0, kind: "userinfo")) else { return false }
            return text[end...].allSatisfy { $0.isWhitespace || "]})>".contains($0) }
        }
        let closers: [Character: Character] = ["<": ">", "{": "}"]
        guard let opener = text[..<start].last, let closer = closers[opener],
              let end = text[start...].firstIndex(of: closer),
              text[text.index(after: end)...].allSatisfy({ $0.isWhitespace || "]})>".contains($0) }) else { return false }
        let content = text[start..<end]
        return !content.contains(opener) && !content.contains(closer)
    }

}
