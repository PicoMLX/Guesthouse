import Foundation

extension Redactor {
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
        }
        if let header = text.firstMatch(of: #/(?:^|[^A-Za-z0-9_-])([A-Za-z-]{1,10})[ \t]*$/#) {
            let prefix = String(header.1).lowercased()
            if ["cookie:", "set-cookie:"].contains(where: { $0.hasPrefix(prefix) }) { return prefix }
        }
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
            || combined.prefixMatch(of: patterns.authorizationHeader) != nil {
            return prefix + line.drop(while: \.isWhitespace)
        }
        let quoted = "\"" + combined
        if quoted.prefixMatch(of: patterns.serializedSecretOption) != nil {
            return "\"" + prefix + line.drop(while: \.isWhitespace)
        }
        return nil
    }
}
