import Foundation

extension Redactor {
    /// Canonicalize encoded JSON credential names before the existing value scanner.
    /// Only object-key positions are considered; values are never decoded or copied into
    /// state. Unknown valid keys retain their original spelling. Malformed or oversized
    /// encoded keys fail closed as a secret field, keeping decoding work bounded.
    /// A key at EOL is normalized too, so bounded label replay can accept a later colon.
    static func normalizingStructuredCredentialKeys(in input: String) -> String {
        input.replacing(#/((?:^|[{\[,])(?:[ \t]|\r\n|\r|\n)*)("(?:[^"\\\r\n]|\\[^\r\n])*\\?")(?=(?:[ \t]|\r\n|\r|\n)*:|[ \t]*$)/#) { match in
            let encoded = match.2
            guard encoded.contains("\\") else { return String(match.0) }
            guard encoded.utf8.prefix(1025).count <= 1024,
                  let name = try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))
            else { return String(match.1) + "\"secret\"" }
            let label = name + ":"
            guard label.wholeMatch(of: patterns.secretLabelOnly) != nil
                || label.wholeMatch(of: patterns.authorizationHeader) != nil
                || label.wholeMatch(of: patterns.codePromptOnly) != nil
            else { return String(match.0) }
            // Never turn decoded control characters or quotes into new output framing.
            let safeName = name.first?.isWhitespace != true && name.last?.isWhitespace != true && name.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || " ._-".contains($0))
            } ? name : "secret"
            return String(match.1) + "\"" + safeName + "\""
        }
    }
}
