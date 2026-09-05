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

    /// A completed quoted field owns only its value, so indented structured siblings cannot
    /// belong to its fold. Encoded diagnostic quotes follow the same closure rules as streams.
    static func isClosedQuotedValue(_ value: Substring) -> Bool {
        closedQuotedValueTail(value) != nil
    }

    static func closedQuotedValueTail(_ value: Substring) -> Substring? {
        let start = value.drop(while: { $0.isWhitespace })
        let depth = start.prefix(while: { $0 == "\\" }).count
        let content = start.dropFirst(depth)
        guard let quote = content.first, quote == "\"" || quote == "'",
              let end = closingQuoteEnd(in: content.dropFirst(), for: .init(delimiter: quote, escapeDepth: depth, kind: "secret"))
        else { return nil }
        return value[end...]
    }

    static func applyPatterns(to input: String, codeExpected: Bool, state: inout StreamState) -> String {
        let p = patterns
        var text = input
        var tailState = StreamState()
        var tails: [(key: String, value: String)] = []
        defer { mergePendingContexts(from: tailState, into: &state) }
        func redactedTail(of value: Substring) -> String {
            guard let tail = closedQuotedValueTail(value), !tail.isEmpty else { return "" }
            return applyPatterns(to: String(tail), codeExpected: false, state: &tailState)
        }
        func deferClosedValue(_ value: Substring, rendered: String) -> String {
            guard isClosedQuotedValue(value) else { return rendered }
            // Keep sanitized fields out of subsequent rules' original-value state.
            var index = tails.count
            var key = "\u{E001}\(index)\u{E002}"
            while input.contains(key) || tails.contains(where: { $0.key == key }) {
                index += 1
                key = "\u{E001}\(index)\u{E002}"
            }
            tails.append((key, rendered))
            return key
        }
        // Recognition and continuation state use the original field, never its replacement
        // marker. Prefixes, quoting, and delimiters therefore cannot change the state policy.
        text = text.replacing(p.authorizationHeader) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.2, kind: "authorization")
            state.expectingAuthorizationValue = state.expectingAuthorizationValue || !isClosedQuotedValue(match.2)
            state.authorizationValueIsOnTheNextLine =
                state.authorizationValueIsOnTheNextLine || valueStartsOnNextLine(match.2)
            return deferClosedValue(match.2, rendered: "\(match.1)Authorization: \(marker("authorization"))\(redactedTail(of: match.2))")
        }
        // Each token rule captures the character in front of the token, which is put back.
        text = text.replacing(p.bearer) { match in "\(match.1)Bearer \(marker("bearer-token"))" }
        text = text.replacing(p.basicAuthorization) { match in
            guard isBasicCredential(match.3) else { return String(match.0) }
            state.expectingAuthorizationValue = true
            return "\(match.1)Basic \(marker("authorization"))"
        }
        text = text.replacing(p.digestAuthorization) { match in
            state.expectingAuthorizationValue = true
            return "\(match.1)Digest \(marker("authorization"))"
        }
        text = text.replacing(p.specializedAuthorization) { match in
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
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.3, kind: "secret")
            labelMayContinue = labelMayContinue || !isClosedQuotedValue(match.3)
            labelAwaitsValue = labelAwaitsValue || valueStartsOnNextLine(match.3)
            return deferClosedValue(match.3, rendered: "\(match.1)\(match.2): \(marker("secret"))\(redactedTail(of: match.3))")
        }
        state.expectingSecretContinuation = labelMayContinue
        text = text.replacing(p.codeField) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.3, kind: "device-code")
            state.expectingDeviceCode = state.expectingDeviceCode || valueStartsOnNextLine(match.3)
            return deferClosedValue(match.3, rendered: "\(match.1)\(match.2): \(marker("device-code"))\(redactedTail(of: match.3))")
        }
        text = text.replacing(p.codePrompt) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.0.dropFirst(match.1.count), kind: "device-code")
            state.expectingDeviceCode = state.expectingDeviceCode || valueStartsOnNextLine(match.0.dropFirst(match.1.count))
            let punctuation = match.0.hasSuffix(".") ? "." : ""
            let value = match.0.dropFirst(match.1.count)
            return deferClosedValue(value, rendered: "\(match.1) \(marker("device-code"))\(punctuation)\(redactedTail(of: value))")
        }
        text = text.replacing(p.codePromptWithoutDelimiter) { match in "\(match.1) \(marker("device-code"))" }
        text = text.replacing(p.declarativeCodePrompt) { match in
            if let value = match.2 {
                state.quotedValue = state.quotedValue ?? unterminatedQuote(in: value, kind: "device-code")
            }
            state.expectingDeviceCode = state.expectingDeviceCode
                || (match.2.map(valueStartsOnNextLine) ?? true)
            let rendered = "\(match.1) \(marker("device-code"))\(match.2.map { redactedTail(of: $0) } ?? "")"
            return match.2.map { deferClosedValue($0, rendered: rendered) } ?? rendered
        }
        text = text.replacing(p.secretLabelOnly) { match in
            labelAwaitsValue = true
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretValue = labelAwaitsValue
        if text.contains(p.mentionsCode) || codeExpected {
            text = applyDeviceCodePattern(to: text)
        }
        // "Your one-time code is:" with the value on the next line. Only a line that asks for a
        // code arms the next one: arming on any mention of the word would replace the failure
        // that follows `process exited with code 1` with a device-code marker.
        if text.contains(p.codePromptOnly) {
            state.expectingDeviceCode = true
        }
        for tail in tails.reversed() { text = text.replacingOccurrences(of: tail.key, with: tail.value) }
        return text
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
