import Foundation

extension Redactor {
    private static let credentialFieldPrefixes: Set<String> = {
        let secrets = ["password", "passphrase", "passwd", "secret", "token", "credential", "credentials", "api key", "private key", "secret key", "secret access key", "access key secret"]
        let modifiers = ["access", "refresh", "auth", "client", "app", "session", "user", "bearer", "private", "shared", "signing", "master", "id", "current", "new", "old", "previous", "confirm", "confirmation"]
        let names = ["authorization", "proxy authorization", "request authorization", "cookie", "cookies", "set cookie", "set cookies", "request cookie", "request cookies", "device code", "user code", "device codes", "user codes"]
            + secrets + modifiers.flatMap { modifier in secrets.map { modifier + $0 } }
        // Canonical comparison accepts camel case and mixed separators without enumerating
        // every separator combination. The retained prefix still keeps its original spelling.
        let fields = names.map { $0.replacingOccurrences(of: " ", with: "") }
        return Set(fields.flatMap { name in (1...name.count).map { String(name.prefix($0)) } })
    }()
    private static let authorizationSchemes = ["basic", "bearer", "digest", "ntlm", "negotiate", "aws4-hmac-sha256"]
    private static let providerStems = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "sk-"]
    /// Only structural label prefixes are retained, never value bytes. Canonicalizing an
    /// option to its longest sensitive suffix bounds state independently of a vendor prefix.
    private static let sensitiveOptionPrefixes: Set<String> = {
        let words = ["password", "passphrase", "passwd", "secret", "token", "credential", "credentials"]
            + ["api key", "private key", "secret key", "secret access key", "access key secret", "device code", "user code", "device codes", "user codes"]
                .flatMap { name in ["", "-", "_"].map { name.replacingOccurrences(of: " ", with: $0) } }
        return Set(words.flatMap { word in (1..<word.count).map { String(word.prefix($0)) } })
    }()

    static func partialCredentialLabel(in text: String) -> String? {
        if let option = text.firstMatch(of: #/(?:^|[\s\u{001F}"'\[({<:=\u{0060},;])(--?[A-Za-z0-9_-]*)[ \t]*$/#) {
            let name = String(option.1).lowercased()
            guard name.wholeMatch(of: patterns.secretOptionOnly) == nil else { return nil }
            if name == "-" || name == "--" { return name }
            if let suffix = sensitiveOptionPrefixes.filter({ name.hasSuffix($0) }).max(by: { $0.count < $1.count }) {
                return "--" + suffix
            }
            // The vendor is irrelevant; only the option-name boundary is needed.
            if name.hasSuffix("-") || name.hasSuffix("_") { return "--" }
        }
        if let header = text.firstMatch(of: #/(?:^|[^A-Za-z0-9])([A-Za-z][A-Za-z0-9_-]{0,47})[ \t]*$/#) {
            let prefix = String(header.1).lowercased()
            // Whole-field matching also starts after a vendor's separator. Retain the
            // longest recognized suffix at those same boundaries, never the vendor bytes.
            for start in prefix.indices where start == prefix.startIndex || "-_".contains(prefix[prefix.index(before: start)]) {
                let suffix = String(prefix[start...])
                if credentialFieldPrefixes.contains(suffix.filter { $0 != "-" && $0 != "_" }) { return suffix }
            }
            if authorizationSchemes.contains(where: { $0.hasPrefix(prefix) && $0 != prefix }) { return prefix }
        }
        let tail = String(text.suffix(11))
        let providerPrefixes = providerStems.flatMap { stem in (1..<stem.count).map { String(stem.prefix($0)) } }
        if let prefix = providerPrefixes.filter({ prefix in
            guard tail.hasSuffix(prefix) else { return false }
            if "sk-".hasPrefix(prefix), let prior = text.dropLast(prefix.count).last,
               prior.isASCII && (prior.isLetter || prior.isNumber) { return false }
            return true
        }).max(by: { $0.count < $1.count }) { return prefix }
        return nil
    }

    /// Called only at a physical record boundary. A mismatching suffix is ordinary text,
    /// and blank/styling-only records do not consume the pending structural prefix.
    static func restoringCredentialLabel(in line: String, state: inout StreamState) -> String? {
        guard let prefix = state.pendingCredentialLabel else { return nil }
        let visible = stripTerminalEscapes(line).drop(while: \.isWhitespace)
        guard !visible.isEmpty else { return nil }
        state.pendingCredentialLabel = nil
        let combined = prefix + visible
        if partialCredentialLabel(in: combined)?.hasPrefix(prefix) == true
            || combined.prefixMatch(of: patterns.secretOption) != nil
            || combined.wholeMatch(of: patterns.secretOptionOnly) != nil
            || combined.prefixMatch(of: patterns.authorizationHeader) != nil
            || combined.prefixMatch(of: patterns.labeledSecret) != nil
            || combined.wholeMatch(of: patterns.secretLabelOnly) != nil
            || combined.prefixMatch(of: patterns.codeField) != nil
            || combined.wholeMatch(of: patterns.codePromptOnly) != nil
            || combined.prefixMatch(of: patterns.githubToken) != nil
            || combined.prefixMatch(of: patterns.apiKey) != nil
            || authorizationSchemes.contains(where: { combined.lowercased().hasPrefix($0 + " ") }) {
            return prefix + line.drop(while: \.isWhitespace)
        }
        let quoted = "\"" + combined
        if quoted.prefixMatch(of: patterns.serializedSecretOption) != nil {
            return "\"" + prefix + line.drop(while: \.isWhitespace)
        }
        return nil
    }
}
