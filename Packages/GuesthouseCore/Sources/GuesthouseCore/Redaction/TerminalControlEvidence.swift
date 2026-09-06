import Foundation

/// A fixed set of scan-only readings, with bounded lookbehind across unfinished commands.
/// No prefix or recovered command byte is ever returned as visible diagnostic text.
enum TerminalControlEvidence {
    enum Reading: Int, CaseIterable, Sendable {
        case joined, parameterless, final, complete
    }

    struct Continuation: Hashable, Sendable {
        let pending: TerminalControlGrammar.Pending
        /// At most four suffixes, each at most 64 Unicode scalars (256 UTF-8 bytes).
        let prefixes: [String]
        fileprivate init(pending: TerminalControlGrammar.Pending, prefixes: [String]) {
            self.pending = pending
            self.prefixes = prefixes
        }
    }

    static func body(of escape: Substring, reading: Reading) -> String {
        guard reading != .joined else { return "" }
        let command = String(String.UnicodeScalarView(escape.unicodeScalars.filter {
            !((0...0x1A).contains($0.value) || (0x1C...0x1F).contains($0.value) || $0.value == 0x7F)
        }))
        let prefix = command.hasPrefix("\u{1B}[") ? 2 : (command.hasPrefix("\u{9B}") ? 1 : 0)
        if prefix > 0, let final = escape.unicodeScalars.last, !(0x40...0x7E).contains(final.value) { return "" }
        // Opaque OSC/DCS/APC/PM/SOS payloads can never become generic-command evidence.
        let generic = command.wholeMatch(of: #/\u{1B}(?![\[\]P_^X])[ -\/]*[0-~]/#) != nil
        guard prefix > 0 || generic else { return "" }
        let complete = String(command.dropFirst(generic ? 1 : prefix))
        switch reading {
        case .joined: return ""
        case .parameterless: return complete.count == 1 ? complete : ""
        case .final: return String(complete.suffix(1))
        case .complete: return complete
        }
    }

    static func prepare(_ line: String, continuation: inout Continuation?) -> (text: String, prefixes: [String]) {
        let prefixes = continuation?.prefixes ?? []
        var pending = continuation?.pending
        let text = TerminalControlGrammar.prepare(line, pending: &pending)
        continuation = pending.map { command in
            let carriesPrefix: Bool
            switch command {
            case .csi, .escape: carriesPrefix = true
            case .osc, .other: carriesPrefix = false
            }
            return Continuation(pending: command, prefixes: carriesPrefix ? Reading.allCases.map { reading in
                suffix(in: text, prefix: prefixes.indices.contains(reading.rawValue) ? prefixes[reading.rawValue] : "", reading: reading)
            } : [])
        }
        return (text, prefixes)
    }

    private static func suffix(in text: String, prefix: String, reading: Reading) -> String {
        // Physical line framing is not part of the credential prefix being carried.
        let end = text.unicodeScalars.lastIndex(where: { $0 != "\r" && $0 != "\n" })
            .map { text.unicodeScalars.index(after: $0) } ?? text.startIndex
        var remaining = text[..<end]
        var result = prefix
        func append(_ literal: Substring) {
            let tail = String(String.UnicodeScalarView(literal.unicodeScalars.suffix(64)))
            result = String(String.UnicodeScalarView((result + tail).unicodeScalars.suffix(64)))
        }
        while let escape = remaining.firstMatch(of: TerminalControlGrammar.escape) {
            append(remaining[..<escape.range.lowerBound])
            append(body(of: escape.0, reading: reading)[...])
            remaining = remaining[escape.range.upperBound...]
        }
        append(remaining)
        return result
    }
}
