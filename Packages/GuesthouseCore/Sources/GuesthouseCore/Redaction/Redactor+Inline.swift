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

    static func applyPatterns(to input: String, codeExpected: Bool, state: inout StreamState) -> String {
        let p = patterns
        var text = input
        // Recognition and continuation state use the original field, never its replacement
        // marker. Prefixes, quoting, and delimiters therefore cannot change the state policy.
        text = text.replacing(p.authorizationHeader) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.2, kind: "authorization")
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine =
                state.authorizationValueIsOnTheNextLine || valueStartsOnNextLine(match.2)
            return "\(match.1)Authorization: \(marker("authorization"))"
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
        // A labeled value can be folded onto the next line, so the label arms the continuation
        // state the way an authorization header does.
        var labelCarriedAValue = false
        // Inspect the original input too: a preceding missing-value option may otherwise
        // consume this last option before the generic rules get to see it.
        var labelAwaitsValue = state.expectingSecretValue || input.contains(p.secretOptionOnly)
        text = text.replacing(p.labeledSecret) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.3, kind: "secret")
            labelCarriedAValue = true
            labelAwaitsValue = labelAwaitsValue || valueStartsOnNextLine(match.3)
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretContinuation = labelCarriedAValue
        text = text.replacing(p.codeField) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.3, kind: "device-code")
            return "\(match.1)\(match.2): \(marker("device-code"))"
        }
        text = text.replacing(p.codePrompt) { match in
            state.quotedValue = state.quotedValue ?? unterminatedQuote(in: match.0.dropFirst(match.1.count), kind: "device-code")
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
        if text.contains(p.mentionsCode) || codeExpected {
            text = applyDeviceCodePattern(to: text)
        }
        // "Your one-time code is:" with the value on the next line. Only a line that asks for a
        // code arms the next one: arming on any mention of the word would replace the failure
        // that follows `process exited with code 1` with a device-code marker.
        if text.contains(p.codePromptOnly) {
            state.expectingDeviceCode = true
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
}
