import Foundation
import RegexBuilder

extension Redactor {
    /// Runs the rules over a line that is replaced whole, so a secret label or a code prompt
    /// inside it still opens the context the next line completes. Nothing the rules produce is
    /// used, and a context that was already open stays open: this line is the value of the fold
    /// it continues, not the value that context is waiting for.
    static func armPendingContexts(from text: String, state: inout StreamState) {
        var scanned = state
        _ = applyPatterns(to: text, codeExpected: false, state: &scanned)
        mergePendingContexts(from: scanned, into: &state)
    }

    static func applyPatterns(to input: String, codeExpected: Bool, state: inout StreamState,
                              prepareQuotedValues: Bool = true) -> String {
        let p = patterns
        let protected = prepareQuotedValues ? protectEncodedQuotedValues(in: input) { value in
            var quotedState = StreamState()
            let sanitized = applyPatterns(to: value, codeExpected: false, state: &quotedState, prepareQuotedValues: false)
            return (sanitized, quotedState)
        } : ProtectedQuotedValues(text: input)
        var text = redactURLContinuations(protected.text, state: &state)
        // Recognition and continuation state use the original field, never its replacement
        // marker. Prefixes, quoting, and delimiters therefore cannot change the state policy.
        text = text.replacing(p.authorizationHeader) { match in
            let explicit = fieldExplicitlyContinues(match.2, tail: text[match.range.upperBound...])
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.2, kind: "authorization")
            state.expectingAuthorizationValue = state.expectingAuthorizationValue || !isClosedQuotedValue(match.2) || explicit
            state.authorizationValueIsOnTheNextLine =
                state.authorizationValueIsOnTheNextLine || valueStartsOnNextLine(match.2) || explicit
            state.authorizationValueExplicitlyContinues = state.authorizationValueExplicitlyContinues || explicit
            let header = match.0[..<match.2.startIndex].lowercased()
            let name = header.contains("set-cookie") ? "Set-Cookie" : header.contains("cookie") ? "Cookie" : "Authorization"
            return "\(match.1)\(name): \(marker("authorization"))"
        }
        // Each token rule captures the character in front of the token, which is put back.
        if text.wholeMatch(of: #/[ \t]*(?i:Basic)[ \t]*(?:\\[ \t]*)?/#) != nil {
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine = true
            state.authorizationValueExplicitlyContinues = valueExplicitlyContinues(text[...])
        }
        text = text.replacing(p.bearer) { match in
            _ = retainExplicitAuthorization(match.2, tail: text[match.range.upperBound...], state: &state)
            return "\(match.1)Bearer \(marker("bearer-token"))"
        }
        text = text.replacing(p.basicAuthorization) { match in
            let explicit = retainExplicitAuthorization(match.3, tail: text[match.range.upperBound...], state: &state)
            guard isBasicCredential(match.3) || explicit else { return String(match.0) }
            state.expectingAuthorizationValue = true
            return "\(match.1)Basic \(marker("authorization"))"
        }
        text = text.replacing(p.digestAuthorization) { match in
            _ = retainExplicitAuthorization(match.0, tail: text[match.range.upperBound...], state: &state)
            state.expectingAuthorizationValue = true
            return "\(match.1)Digest \(marker("authorization"))"
        }
        text = text.replacing(p.specializedAuthorization) { match in
            _ = retainExplicitAuthorization(match.0, tail: text[match.range.upperBound...], state: &state)
            state.expectingAuthorizationValue = true
            return "\(match.1)\(marker("authorization"))"
        }
        // The GitHub rule captures nothing in front of the token: it needs no boundary there.
        text = text.replacing(p.githubToken, with: marker("github-token"))
        text = text.replacing(p.distinctiveAPIKey, with: marker("api-key"))
        text = text.replacing(p.apiKey) { match in "\(match.1)\(marker("api-key"))" }
        text = text.replacing(p.jwt) { match in "\(match.1)\(redactedJWT(match.2))" }
        text = text.replacing(p.urlUserInfo) { match in "\(match.1)\(marker("userinfo"))@" }
        // Scan argv boundaries before generic labelled values can consume following options.
        text = redactSerializedOptions(text, state: &state)
        text = redactSecretOptions(text, state: &state)
        // Unquoted or unfinished quoted values can fold onto the next line. A closing quote
        // bounds a completed structured value even when the next sibling is indented.
        var labelMayContinue = false
        // Inspect the original input too: a preceding missing-value option may otherwise
        // consume this last option before the generic rules get to see it.
        var labelAwaitsValue = state.expectingSecretValue || input.contains(p.secretOptionOnly)
        text = text.replacing(p.labeledSecret) { match in
            let explicit = fieldExplicitlyContinues(match.3, tail: text[match.range.upperBound...])
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.3, kind: "secret")
            labelMayContinue = labelMayContinue || !isClosedQuotedValue(match.3) || explicit
            labelAwaitsValue = labelAwaitsValue || valueStartsOnNextLine(match.3) || explicit
            state.secretValueExplicitlyContinues = state.secretValueExplicitlyContinues || explicit
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretContinuation = labelMayContinue
        text = text.replacing(p.codeField) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.3, kind: "device-code")
            state.expectingDeviceCode = state.expectingDeviceCode || valueStartsOnNextLine(match.3)
                || fieldExplicitlyContinues(match.3, tail: text[match.range.upperBound...])
            return "\(match.1)\(match.2): \(marker("device-code"))"
        }
        text = text.replacing(p.codePrompt) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.0.dropFirst(match.1.count), kind: "device-code")
            state.expectingDeviceCode = state.expectingDeviceCode || valueStartsOnNextLine(match.0.dropFirst(match.1.count))
            let punctuation = match.0.hasSuffix(".") ? "." : ""
            return "\(match.1) \(marker("device-code"))\(punctuation)"
        }
        text = text.replacing(p.codePromptWithoutDelimiter) { match in "\(match.1) \(marker("device-code"))" }
        text = text.replacing(p.declarativeCodePrompt) { match in
            if let value = match.2 {
                state.quotedValue = state.quotedValue ?? unterminatedQuote(in: value, kind: "device-code")
            }
            state.expectingDeviceCode = state.expectingDeviceCode
                || (match.2.map(valueStartsOnNextLine) ?? true)
            return "\(match.1) \(marker("device-code"))"
        }
        text = text.replacing(p.secretLabelOnly) { match in
            labelAwaitsValue = true
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretValue = labelAwaitsValue
        // "Your one-time code is:" with the value on the next line. Only a line that asks for a
        // code arms the next one: arming on any mention of the word would replace the failure
        // that follows `process exited with code 1` with a device-code marker.
        if text.contains(p.codePromptOnly) {
            state.expectingDeviceCode = true
        }
        text = protected.restoring(in: text, state: &state)
        if text.contains(p.mentionsCode) || codeExpected {
            text = applyDeviceCodePattern(to: text)
        }
        return text
    }

    private static func retainExplicitAuthorization(_ value: Substring, tail: Substring, state: inout StreamState) -> Bool {
        let explicit = valueExplicitlyContinues(value)
            || (tail.allSatisfy({ $0.isWhitespace || $0 == "\\" }) && valueExplicitlyContinues(tail))
        if explicit {
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine = true
            state.authorizationValueExplicitlyContinues = true
        }
        return explicit
    }

    /// Stream output cannot retract an earlier fragment after a later @ proves it sensitive.
    /// Ambiguous bare host:port authorities at EOL therefore take the conservative path too.
    /// A visible path/query/fragment boundary proves the authority complete (RFC 3986 §3.2).
    private static func redactURLContinuations(_ input: String, state: inout StreamState) -> String {
        var text = input
        if state.expectingURLUserInfo {
            let value = text.drop(while: \.isWhitespace)
            guard !value.isEmpty else { return text }
            let end = value.firstIndex(where: { $0.isWhitespace || "/?#".contains($0) }) ?? text.endIndex
            let at = text[value.startIndex..<end].lastIndex(of: "@")
            state.expectingURLUserInfo = at == nil && end == text.endIndex
            let stop = at ?? end
            text = String(text[..<value.startIndex]) + marker("userinfo") + text[stop...]
        }
        return text.replacing(patterns.incompleteURLUserInfo) { match in
            if hasCompleteURLFrame(in: text, prefixEnd: match.1.endIndex) { return String(match.0) }
            state.expectingURLUserInfo = true
            return String(match.1) + marker("userinfo")
        }
    }

    /// Only a matching, same-record outer frame proves closure. Parentheses/apostrophes
    /// can be real URI userinfo characters, so an arbitrary trailing delimiter is not enough.
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
        let closers: [Character: Character] = ["(": ")", "<": ">", "\"": "\"", "'": "'"]
        guard let opener = text[..<start].last, let closer = closers[opener], text.last == closer else { return false }
        let content = text[start..<text.index(before: text.endIndex)]
        return !content.contains(opener) && !content.contains(closer)
    }

    static func applyDeviceCodePattern(to input: String, preserveAlgorithms: Bool = false) -> String {
        input.replacing(patterns.deviceCode) { match in
            // Only context-free shape matching has this exception. Explicit credential fields
            // and code prompts still remove even a value that happens to name an algorithm.
            if preserveAlgorithms, match.2.wholeMatch(of: #/(?:HMAC|ECDSA|RSA)-SHA(?:1|224|256|384|512)|PBKDF2-HMAC-SHA(?:1|224|256|384|512)|CHACHA20-POLY1305/#) != nil {
                return String(match.0)
            }
            return "\(match.1)\(marker("device-code"))"
        }
    }
}
