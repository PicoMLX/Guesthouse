import Foundation
import RegexBuilder

extension Redactor {
    /// Scan a wholly concealed record for new contexts without clearing existing folds.
    static func armPendingContexts(from text: String, state: inout StreamState) {
        var scanned = state
        _ = applyPatterns(to: text, codeExpected: false, state: &scanned)
        mergePendingContexts(from: scanned, into: &state)
    }

    static func applyPatterns(to input: String, codeExpected: Bool, state: inout StreamState,
                              prepareQuotedValues: Bool = true) -> String {
        let p = patterns
        state.pendingCredentialLabel = partialCredentialLabel(in: input) ?? state.pendingCredentialLabel
        let protected = prepareQuotedValues ? protectEncodedQuotedValues(in: input) { value in
            var quotedState = StreamState()
            let sanitized = applyPatterns(to: value, codeExpected: false, state: &quotedState, prepareQuotedValues: false)
            // This encoded container is closed. Inner field fragments cannot own a
            // later physical record; independently recognized PEM state still can.
            var boundedState = StreamState()
            boundedState.pemLabel = quotedState.pemLabel
            return (sanitized, boundedState)
        } : ProtectedQuotedValues(text: input)
        var originalURLContext = StreamState()
        let original = state.expectingURLUserInfo
            ? applyPatterns(to: protected.text, codeExpected: codeExpected, state: &originalURLContext, prepareQuotedValues: false)
            : protected.text
        defer { mergePendingContexts(from: originalURLContext, into: &state) }
        var text = redactURLContinuations(original, state: &state)
        // Continuation state uses the original field, never its replacement marker.
        text = text.replacing(p.authorizationHeader) { match in
            let explicit = fieldExplicitlyContinues(match.2, tail: text[match.range.upperBound...])
                || match.2.last(where: { !$0.isWhitespace }) == ","
            state.quotedValue = state.quotedValue ?? unterminatedAuthorizationQuote(in: match.2)
            state.expectingAuthorizationValue = state.expectingAuthorizationValue || !isClosedQuotedValue(match.2) || explicit
            state.authorizationValueIsOnTheNextLine =
                state.authorizationValueIsOnTheNextLine || valueStartsOnNextLine(match.2) || explicit
                || match.2.trimmingCharacters(in: .whitespacesAndNewlines)
                    .wholeMatch(of: #/(?i:Basic|Bearer|Digest|NTLM|Negotiate|AWS4-HMAC-SHA256)/#) != nil
            state.authorizationValueExplicitlyContinues = state.authorizationValueExplicitlyContinues || explicit
            let header = match.0[..<match.2.startIndex].lowercased()
            let name = header.contains("set-cookie") ? "Set-Cookie" : header.contains("cookie") ? "Cookie" : "Authorization"
            return "\(match.1)\(name): \(marker("authorization"))"
        }
        // Each token rule captures the character in front of the token, which is put back.
        if text.wholeMatch(of: #/[ \t]*(?i:Basic|Bearer|Digest|NTLM|Negotiate|AWS4-HMAC-SHA256)[ \t]*(?:\[redacted:[^\]\r\n]+\][ \t]*)*(?:\\[ \t]*)?/#) != nil {
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine = true
            state.authorizationValueExplicitlyContinues = valueExplicitlyContinues(text[...])
        }
        text = text.replacing(p.partialParameterizedAuthorization) { match in
            let names = match.2.lowercased() == "digest"
                ? ["username", "username*", "realm", "nonce", "uri", "response", "algorithm", "cnonce", "opaque", "qop", "nc", "userhash"]
                : ["credential", "signedheaders", "signature"]
            guard names.contains(where: { $0.hasPrefix(match.3.lowercased()) }) else { return String(match.0) }
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine = true
            return "\(match.1)\(match.2) \(marker("authorization"))"
        }
        text = text.replacing(p.partialIntegratedAuthorization) { match in
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine = true
            return "\(match.1)\(match.2) \(marker("authorization"))"
        }
        text = text.replacing(p.bearer) { match in
            _ = retainExplicitAuthorization(match.2, tail: text[match.range.upperBound...], state: &state)
            state.expectingAuthorizationValue = true
            return "\(match.1)Bearer \(marker("bearer-token"))"
        }
        text = text.replacing(p.basicAuthorization) { match in
            let explicit = retainExplicitAuthorization(match.3, tail: text[match.range.upperBound...], state: &state)
            // A physical break may arrive before the decoded username/password colon.
            let partialAtEnd = text[match.range.upperBound...].allSatisfy(\.isWhitespace)
            guard isBasicCredential(match.3) || explicit || partialAtEnd else { return String(match.0) }
            state.expectingAuthorizationValue = true
            state.authorizationValueIsOnTheNextLine = state.authorizationValueIsOnTheNextLine
                || (partialAtEnd && !isBasicCredential(match.3))
            return "\(match.1)Basic \(marker("authorization"))"
        }
        text = text.replacing(p.digestAuthorization) { match in
            state.quotedValue = state.quotedValue ?? unterminatedAuthorizationQuote(in: match.0)
            if match.0.last(where: { !$0.isWhitespace }) == "," { state.authorizationValueIsOnTheNextLine = true }
            _ = retainExplicitAuthorization(match.0, tail: text[match.range.upperBound...], state: &state)
            state.expectingAuthorizationValue = true
            return "\(match.1)Digest \(marker("authorization"))"
        }
        text = text.replacing(p.specializedAuthorization) { match in
            state.quotedValue = state.quotedValue ?? unterminatedAuthorizationQuote(in: match.0)
            if match.0.last(where: { !$0.isWhitespace }) == "," { state.authorizationValueIsOnTheNextLine = true }
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
        // Unfinished values can fold; a closing quote bounds a completed structured value.
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
            retainDeviceCodeContext(match.3, tail: text[match.range.upperBound...], state: &state)
            return "\(match.1)\(match.2): \(marker("device-code"))"
        }
        text = text.replacing(p.codePrompt) { match in
            retainDeviceCodeContext(match.0.dropFirst(match.1.count), tail: text[match.range.upperBound...], state: &state)
            let punctuation = match.0.hasSuffix(".") ? "." : ""
            return "\(match.1) \(marker("device-code"))\(punctuation)"
        }
        text = text.replacing(p.codePromptWithoutDelimiter) { match in
            retainDeviceCodeContext(match.0.dropFirst(match.1.count), tail: text[match.range.upperBound...], state: &state)
            state.expectingDeviceCode = state.expectingDeviceCode
                || (match.2.first.map({ $0.isLetter || $0.isNumber }) == true
                    && match.2.lazy.filter { $0.isLetter || $0.isNumber }.prefix(4).count < 4
                    && text[match.range.upperBound...].allSatisfy(\.isWhitespace))
            return "\(match.1) \(marker("device-code"))"
        }
        text = text.replacing(p.declarativeCodePrompt) { match in
            if let value = match.2 {
                retainDeviceCodeContext(value, tail: text[match.range.upperBound...], state: &state)
            }
            state.expectingDeviceCode = state.expectingDeviceCode
                || (match.2.map(valueStartsOnNextLine) ?? true)
            return "\(match.1) \(marker("device-code"))"
        }
        text = text.replacing(p.secretLabelOnly) { match in
            labelAwaitsValue = true
            return "\(match.1)\(match.2): \(marker("secret"))"
        }
        state.expectingSecretValue = labelAwaitsValue || input.contains(p.secretLabelOnly)
        // "Your one-time code is:" with the value on the next line. Only a line that asks for a
        // code arms the next one: arming on any mention of the word would replace the failure
        // that follows `process exited with code 1` with a device-code marker.
        if text.contains(p.codePromptOnly) || input.contains(p.codePromptOnly) {
            state.expectingDeviceCode = true
        }
        text = protected.restoring(in: text, state: &state)
        if text.contains(p.mentionsCode) || codeExpected {
            text = applyDeviceCodePattern(to: text)
        }
        return text
    }

    private static func retainDeviceCodeContext(_ value: Substring, tail: Substring, state: inout StreamState) {
        let explicit = fieldExplicitlyContinues(value, tail: tail)
            || (tail.allSatisfy({ $0.isWhitespace || $0 == "\\" }) && valueExplicitlyContinues(tail))
        state.quotedValue = state.quotedValue ?? unterminatedQuote(in: value, kind: "device-code")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let frames: [Character: Character] = ["[": "]", "(": ")", "<": ">", "`": "`"]
        if let opener = trimmed.first, let closer = frames[opener], !trimmed.dropFirst().contains(closer) {
            state.quotedValue = state.quotedValue ?? .init(delimiter: closer, escapeDepth: 0, kind: "device-code")
        }
        let unfinishedGroup = trimmed.wholeMatch(of: #/[A-Z0-9]{1,8}(?:[-.][A-Z0-9]{1,8})*[-.]/#) != nil
            && !trimmed.dropLast().contains(patterns.deviceCode)
        state.expectingDeviceCode = state.expectingDeviceCode || valueStartsOnNextLine(value) || explicit || unfinishedGroup
        state.expectingDeviceCodeContinuation = state.expectingDeviceCodeContinuation || !isClosedQuotedValue(value) || explicit
    }

    /// Parameter quotes can wrap even when the enclosing authorization value is unquoted.
    /// Keep only the delimiter/depth and enclosing fold, never parameter payload bytes.
    static func unterminatedAuthorizationQuote(in value: Substring) -> StreamState.QuotedValue? {
        if isClosedQuotedValue(value) { return nil }
        if let whole = unterminatedQuote(in: value, kind: "authorization") { return whole }
        var cursor = value.startIndex
        while let opener = value[cursor...].firstMatch(of: #/=[ \t]*(\\*)(["'])/#) {
            guard let delimiter = opener.2.first else { return nil }
            let quoted = StreamState.QuotedValue(delimiter: delimiter, escapeDepth: opener.1.count,
                kind: "authorization", enclosingAuthorizationFold: true)
            guard let end = closingQuoteEnd(in: value[opener.range.upperBound...], for: quoted) else { return quoted }
            cursor = end
        }
        return nil
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
