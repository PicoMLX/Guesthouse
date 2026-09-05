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
                              prepareQuotedValues: Bool = true, encodingDepth: Int = 0) -> String {
        let p = patterns
        let protected = prepareQuotedValues ? protectEncodedQuotedValues(in: input) { value in
            // Each recursive step removes one encoding layer from this bounded value, never
            // rescans its siblings or a remaining suffix. Excessive nesting fails closed.
            guard encodingDepth < 8 else { return (marker("secret"), StreamState()) }
            var quotedState = StreamState()
            let sanitized = applyPatterns(to: value, codeExpected: false, state: &quotedState, prepareQuotedValues: false)
            let normalized = unwrappingCompleteDecodedString(removingQuotedEncodingLayer(value))
                .replacing(#/\\+[nrtfv]/#, with: " ")
            var nestedState = StreamState()
            let nested = applyPatterns(to: normalized, codeExpected: false, state: &nestedState,
                                       encodingDepth: encodingDepth + 1)
            // The encoded value has already closed. Its decoded, possibly truncated contents
            // cannot acquire a value from a later unrelated physical record.
            // Do not attempt to splice decoded offsets back into multiply escaped text.
            // Hide the containing value if the decoded reading adds credential evidence.
            if nested != normalized || incompleteJWTStartAtLineEnd(in: normalized) != nil {
                return (marker("secret"), quotedState)
            }
            return (sanitized, quotedState)
        } : ProtectedQuotedValues(text: input)
        var text = protected.text
        // Retain original DSN coverage independently of replacements that can erase its
        // transport suffix. Field parsing below still owns original continuation state.
        let dsnText = redactingMySQLUserInfo(protected.text)
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
            let compactHeader = header.filter { $0 != "-" && $0 != "_" && !$0.isWhitespace }
            let name = compactHeader.contains("setcookie") ? "Set-Cookie" : header.contains("cookie") ? "Cookie" : "Authorization"
            return "\(match.1)\(name): \(marker("authorization"))"
        }
        // Each token rule captures the character in front of the token, which is put back.
        if text.wholeMatch(of: #/[ \t]*(?i:Bearer)[ \t]*(?:\\[ \t]*)?/#) != nil {
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine = true
            state.authorizationValueExplicitlyContinues = valueExplicitlyContinues(text[...])
        }
        text = text.replacing(p.bearer) { match in
            let tail = text[match.range.upperBound...]
            if tail.allSatisfy({ $0.isWhitespace || $0 == "\\" }), valueExplicitlyContinues(tail) {
                state.expectingAuthorizationValue = true
                state.authorizationValueIsOnTheNextLine = true
                state.authorizationValueExplicitlyContinues = true
            }
            return "\(match.1)Bearer \(marker("bearer-token"))"
        }
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
            let value = match.0.dropFirst(match.1.count)
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: value, kind: "device-code")
            state.expectingDeviceCode = state.expectingDeviceCode || valueStartsOnNextLine(value)
                || fieldExplicitlyContinues(value, tail: text[match.range.upperBound...])
            let punctuation = match.0.hasSuffix(".") ? "." : ""
            return "\(match.1) \(marker("device-code"))\(punctuation)"
        }
        text = text.replacing(p.codePromptWithoutDelimiter) { match in
            let tail = text[match.range.upperBound...]
            state.expectingDeviceCode = state.expectingDeviceCode
                || (tail.allSatisfy({ $0.isWhitespace || $0 == "\\" }) && valueExplicitlyContinues(tail))
            return "\(match.1) \(marker("device-code"))"
        }
        text = text.replacing(p.declarativeCodePrompt) { match in
            if let value = match.2 {
                state.quotedValue = state.quotedValue ?? unterminatedQuote(in: value, kind: "device-code")
                state.expectingDeviceCode = state.expectingDeviceCode
                    || fieldExplicitlyContinues(value, tail: text[match.range.upperBound...])
                    || (text[match.range.upperBound...].allSatisfy({ $0.isWhitespace || $0 == "\\" })
                        && valueExplicitlyContinues(text[match.range.upperBound...]))
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
        if dsnText != protected.text {
            // Overlapping interpretations have incompatible replaced offsets. Conceal the
            // containing line instead of allowing either replacement to hide the other's evidence.
            text = text == protected.text ? dsnText : marker("userinfo")
        }
        text = protected.restoring(in: text, state: &state)
        if text.contains(p.mentionsCode) || codeExpected {
            text = applyDeviceCodePattern(to: text, preserveAlgorithms: !codeExpected)
        }
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

    private static func redactingMySQLUserInfo(_ input: String) -> String {
        guard let end = input.matches(of: patterns.mysqlTransport).last?.range.upperBound else { return input }
        let assigned = input[..<end].replacing(patterns.mysqlAssignedUserInfo) { "\($0.1)\(marker("userinfo"))\($0.2)" }
        let remaining = assigned.replacing(patterns.mysqlUserInfo) { "\($0.1)\(marker("userinfo"))\($0.2)" }
        return String(remaining) + input[end...]
    }
}
