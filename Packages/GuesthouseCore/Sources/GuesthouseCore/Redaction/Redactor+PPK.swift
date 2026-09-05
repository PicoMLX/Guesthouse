import RegexBuilder

extension Redactor {
    /// PuTTY framing, not key validation: metadata and both key halves are all hidden.
    /// https://www.puttyssh.org/0.83/htmldoc/AppendixC.html
    /// Counts only bound the expected sequence; they never size an allocation or end protection.
    /// A malformed sequence stays closed until the caller supplies a fresh StreamState.
    /// An embedded opener fails closed too. Framing requires original physical key lines;
    /// arbitrary logger prefixes are not stripped from untrusted key material to guess a footer.
    /// Call exactly once per physical line, after removing terminal controls and their payloads.
    static func consumePPKLine(_ line: String, phase: inout StreamState.PPKPhase) -> Bool {
        switch phase {
        case .inactive:
            // The distinctive opener also survives a logger prefix or an enclosing quoted value.
            guard let start = line.firstMatch(of: patterns.ppkBegin) else { return false }
            // Legacy v1 and unknown versions still identify private keys. Without a supported
            // closing grammar, conceal the rest of this stream rather than guessing its end.
            phase = start.1 == "2" || start.1 == "3"
                ? .headers(macDigits: start.1 == "2" ? 40 : 64) : .invalid
        case .headers(let macDigits):
            if let count = line.wholeMatch(of: #/[ \t]*Private-Lines:[ \t]*([0-9]+)[ \t]*/#),
               let remaining = Int(count.1), remaining > 0 {
                phase = .privateLines(remaining: remaining, macDigits: macDigits)
            } else if line.firstMatch(of: #/^[ \t]*(?:Private-Lines|Private-MAC)(?:[: \t]|$)/#) != nil {
                phase = .invalid
            }
            // Public data, comments, encryption and KDF metadata are opaque, not trusted counts.
        case .privateLines(let remaining, let macDigits):
            guard let body = line.wholeMatch(of: #/[ \t]*([A-Za-z0-9+\/]+={0,2})[ \t]*/#),
                  remaining == 1 || !body.1.hasSuffix("=") else {
                phase = .invalid
                return true
            }
            phase = remaining == 1 ? .mac(digits: macDigits)
                : .privateLines(remaining: remaining - 1, macDigits: macDigits)
        case .mac(let digits):
            if let mac = line.wholeMatch(of: #/[ \t]*Private-MAC:[ \t]*([0-9A-Fa-f]+)[ \t]*/#),
               mac.1.utf8.count == digits {
                phase = .inactive
            } else {
                phase = .invalid
            }
        case .invalid:
            break
        }
        // The complete MAC line is sensitive too. Ordinary parsing resumes on the next line,
        // without clearing any quoted, PEM, or pending context that enclosed this block.
        return true
    }
}
