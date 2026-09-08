import Foundation

extension Redactor {
    private static let credentialFieldPrefixes: Set<String> = {
        let secrets = ["password", "passphrase", "passwd", "secret", "token", "credential", "api key", "private key", "secret key", "secret access key", "access key secret"]
            .flatMap { [$0, $0 + "s"] }
        let modifiers = ["access", "refresh", "auth", "client", "app", "session", "user", "bearer", "private", "shared", "signing", "master", "id", "current", "new", "old", "previous", "confirm", "confirmation"]
        let qualifiers = ["your", "one time", "verification", "activation", "confirmation", "pairing", "login", "security", "authorization", "auth", "access", "user", "device"]
        let names = ["authorization", "proxy authorization", "request authorization", "cookie", "cookies", "set cookie", "set cookies", "request cookie", "request cookies", "device code", "user code", "device codes", "user codes", "code", "codes"]
            + qualifiers.flatMap { [$0 + " code", $0 + " codes"] }
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
        let words = ["password", "passphrase", "passwd", "secret", "token", "credential"].flatMap { [$0, $0 + "s"] }
            + ["api key", "private key", "secret key", "secret access key", "access key secret", "device code", "user code", "device codes", "user codes"]
                .flatMap { name in ["", "-", "_", "."].map { name.replacingOccurrences(of: " ", with: $0) } }
        return Set(words.flatMap { word in (1..<word.count).map { String(word.prefix($0)) } })
    }()

    static func partialCredentialLabel(in text: String) -> String? {
        // Retain known prompt structure, never the arbitrary instruction words between it.
        // A completed keyword needs a canonical space before a later copula or value.
        func promptPrefix(_ verb: Substring, _ keyword: Substring, separator: String = " ") -> String {
            let word = keyword.lowercased()
            return verb.lowercased() + separator + word + (word == "code" || word == "codes" ? " " : "")
        }
        if let option = text.firstMatch(of: #/(?:^|[\s\u{001F}"'\[({<:=\u{0060},;])(--?[A-Za-z0-9_.-]*)[ \t]*$/#) {
            let name = String(option.1).lowercased()
            guard name.wholeMatch(of: patterns.secretOptionOnly) == nil else { return nil }
            if name == "-" || name == "--" { return name }
            if let suffix = sensitiveOptionPrefixes.filter({ name.hasSuffix($0) }).max(by: { $0.count < $1.count }) {
                return "--" + suffix
            }
            // A split may occur inside a modifier (for example --cl / ient-secret).
            // Keep the option boundary, not a field-only prefix without its dashes.
            let tail = String(name.suffix(48))
            for start in tail.indices where tail[start].isLetter {
                let suffix = String(tail[start...])
                if credentialFieldPrefixes.contains(suffix.filter { $0 != "-" && $0 != "_" && $0 != "." }) { return "--" + suffix }
            }
            // The vendor is irrelevant; only the option-name boundary is needed.
            return "--"
        }
        // Option syntax is stronger evidence than a prompt-like suffix inside its name.
        if let prompt = text.firstMatch(of: #/(?:^|[^A-Za-z0-9])((?i:enter|type|paste|copy|input))(?:[ \t]+\S+){0,3}?[ \t]+((?i:c|co|cod|code|codes))[ \t]*$/#) {
            return promptPrefix(prompt.1, prompt.2)
        }
        if let prompt = text.firstMatch(of: #/(?:^|[^A-Za-z0-9])((?i:your|one[ _-]?time|verification|activation|confirmation|pairing|login|security|authorization|auth|access|user|device))([ ._-]?)((?i:c|co|cod|code|codes))[ \t]*$/#) {
            return promptPrefix(prompt.1, prompt.3, separator: String(prompt.2))
        }
        // Compare provider stems with field suffixes; neither may steal a longer prefix.
        let unpadded = text.dropLast(text.reversed().prefix(while: { $0 == " " || $0 == "\t" }).count)
        let tail = String(unpadded.suffix(11))
        let providerPrefixes = providerStems.flatMap { stem in (1..<stem.count).map { String(stem.prefix($0)) } }
        let providerPrefix = providerPrefixes.filter({ prefix in
            guard tail.hasSuffix(prefix) else { return false }
            if "sk-".hasPrefix(prefix), let prior = unpadded.dropLast(prefix.count).last,
               prior.isASCII && (prior.isLetter || prior.isNumber) { return false }
            return true
        }).max(by: { $0.count < $1.count })
        // Keep bounded multiword names and ignore a completed label's quote wrapper.
        // No value has begun before the assignment delimiter; quote depth is not value state.
        if let header = text.firstMatch(of: #/(?:^|[^A-Za-z0-9])([A-Za-z][A-Za-z0-9_. \t-]{0,47})(?:\\*["'])?\\*[ \t]*$/#) {
            let prefix = header.1.trimmingCharacters(in: .whitespaces).lowercased()
            // A whole scheme prefix is stronger evidence than an incidental field suffix.
            if authorizationSchemes.contains(where: { $0.hasPrefix(prefix) && $0 != prefix }) { return prefix }
            // Whole-field matching also starts after a vendor's separator. Retain the
            // longest recognized suffix at those same boundaries, never the vendor bytes.
            for start in prefix.indices where start == prefix.startIndex || "-_. \t".contains(prefix[prefix.index(before: start)]) {
                let suffix = String(prefix[start...])
                if authorizationSchemes.contains(where: { $0.hasPrefix(suffix) && $0 != suffix }) { return suffix }
                if credentialFieldPrefixes.contains(suffix.filter { $0 != "-" && $0 != "_" && $0 != "." && !$0.isWhitespace }) {
                    return (providerPrefix?.count ?? 0) > suffix.count ? providerPrefix : suffix
                }
            }
        }
        return providerPrefix
    }

    /// Called only at a physical record boundary. A mismatching suffix is ordinary text,
    /// and blank/styling-only records do not consume the pending structural prefix.
    /// The physical API supplies normalized joined/spliced readings; preserve their
    /// internal boundary markers in the restored output rather than replaying raw controls.
    static func restoringCredentialLabel(in line: String, state: inout StreamState) -> String? {
        guard let prefix = state.pendingCredentialLabel else { return nil }
        let visible = stripTerminalEscapes(line).drop(while: \.isWhitespace)
        guard !visible.isEmpty else { return nil }
        state.pendingCredentialLabel = nil
        let combined = prefix + visible
        // An unknown qualifier carries only an option boundary across more name fragments.
        // It must not inject synthetic dashes into ordinary visible diagnostics.
        if prefix == "--", partialCredentialLabel(in: combined) == "--",
           combined.wholeMatch(of: #/--?[A-Za-z0-9_.-]+[ \t]*/#) != nil {
            state.pendingCredentialLabel = "--"
            return nil
        }
        if partialCredentialLabel(in: combined).map({ successor in
            successor.hasPrefix(prefix) || (prefix.hasPrefix("-")
                && combined.wholeMatch(of: #/--?[A-Za-z0-9_.-]+[ \t]*/#) != nil
                && credentialFieldPrefixes.contains(combined.lowercased().filter { $0 != "-" && $0 != "_" && $0 != "." && !$0.isWhitespace }))
        }) == true
            || combined.prefixMatch(of: patterns.secretOption) != nil
            || combined.wholeMatch(of: patterns.secretOptionOnly) != nil
            || combined.prefixMatch(of: patterns.authorizationHeader) != nil
            || combined.prefixMatch(of: patterns.labeledSecret) != nil
            || combined.wholeMatch(of: patterns.secretLabelOnly) != nil
            || combined.prefixMatch(of: patterns.codeField) != nil
            || combined.prefixMatch(of: patterns.codePrompt) != nil
            || combined.prefixMatch(of: patterns.codePromptWithoutDelimiter) != nil
            || combined.prefixMatch(of: patterns.declarativeCodePrompt) != nil
            || combined.wholeMatch(of: patterns.codePromptOnly) != nil
            || combined.prefixMatch(of: patterns.githubToken) != nil
            || combined.prefixMatch(of: patterns.apiKey) != nil
            || authorizationSchemes.contains(combined.lowercased())
            || authorizationSchemes.contains(where: {
                combined.lowercased().hasPrefix($0)
                    && combined.dropFirst($0.count).first.map { $0 == " " || $0 == "\t" } == true
            }) {
            return prefix + line.drop(while: \.isWhitespace)
        }
        let quoted = "\"" + combined
        if quoted.prefixMatch(of: patterns.serializedSecretOption) != nil {
            return "\"" + prefix + line.drop(while: \.isWhitespace)
        }
        return nil
    }
}
