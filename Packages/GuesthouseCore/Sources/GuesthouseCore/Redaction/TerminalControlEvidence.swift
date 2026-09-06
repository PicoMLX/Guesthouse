import Foundation

/// Scan-only terminal evidence. Every command independently chooses a reading; no recovered
/// byte becomes visible. Ambiguity exceeding the fixed budget quarantines the rest of a stream.
enum TerminalControlEvidence {
    enum Reading: Int, CaseIterable, Sendable {
        case joined, parameterless, final, intermediates, complete
    }

    static let maximumAlternatives = 64
    static let quarantineMarker = "[redacted:terminal-ambiguity]"

    struct Continuation: Hashable, Sendable {
        let pending: TerminalControlGrammar.Pending?
        /// At most 64 distinct suffixes of at most 64 Unicode scalars (256 UTF-8 bytes).
        let prefixes: [String]
        let commandSuffix: String
        let quarantined: Bool
        fileprivate init(pending: TerminalControlGrammar.Pending?, prefixes: [String],
                         commandSuffix: String, quarantined: Bool = false) {
            self.pending = pending
            self.prefixes = prefixes
            self.commandSuffix = commandSuffix
            self.quarantined = quarantined
        }
    }

    /// Offsets project each UTF-8 boundary back to the control-stripped visible record.
    struct Projection: Hashable, Sendable {
        var text: String
        var offsets: [Int]
        var retained: [Range<Int>]
        var boundaries: Set<Int> = [0]

        fileprivate init(prefix: String) {
            text = prefix
            offsets = Array(repeating: 0, count: prefix.utf8.count + 1)
            retained = prefix.isEmpty ? [] : [0..<prefix.utf8.count]
        }

        fileprivate mutating func append(literal: Substring) {
            var count = offsets.last ?? 0
            text += literal
            for _ in literal.utf8 { count += 1; offsets.append(count) }
        }

        fileprivate mutating func append(body: String) {
            boundaries.insert(offsets.count - 1)
            guard !body.isEmpty else { return }
            let start = offsets.count - 1
            text += body
            offsets.append(contentsOf: repeatElement(offsets.last ?? 0, count: body.utf8.count))
            retained.append(start..<(offsets.count - 1))
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
        case .intermediates:
            // CSI parameters and intermediates are distinct grammar classes. Removing
            // numeric parameters must not discard option punctuation such as a dash.
            return prefix > 0 ? String(String.UnicodeScalarView(complete.unicodeScalars.filter {
                !(0x30...0x3F).contains($0.value)
            })) : complete
        case .complete: return complete
        }
    }

    /// Nil means that no safe bounded enumeration is possible. Do not silently drop
    /// alternatives: the missing reading might be the only one containing the credential.
    static func projections(in text: String, prefixes: [String] = []) -> [Projection]? {
        var results = Array(Set(prefixes.isEmpty ? [""] : prefixes)).sorted().map { Projection(prefix: $0) }
        guard results.count <= maximumAlternatives else { return nil }
        var remaining = text[...]
        while let escape = remaining.firstMatch(of: TerminalControlGrammar.escape) {
            let literal = remaining[..<escape.range.lowerBound]
            let bodies = Array(Set(Reading.allCases.map { body(of: escape.0, reading: $0) })).sorted()
            var next: [Projection] = []
            var seen: Set<Projection> = []
            for var result in results {
                result.append(literal: literal)
                for body in bodies {
                    var candidate = result
                    candidate.append(body: body)
                    if seen.insert(candidate).inserted {
                        guard next.count < maximumAlternatives else { return nil }
                        next.append(candidate)
                    }
                }
            }
            results = next
            remaining = remaining[escape.range.upperBound...]
        }
        return results.map { result in
            var result = result
            result.append(literal: remaining)
            return result
        }
    }

    static func prepare(_ line: String, continuation: inout Continuation?) -> (text: String, prefixes: [String]) {
        let prefixes = continuation?.prefixes ?? []
        var pending = continuation?.pending
        var commandSuffix = continuation?.commandSuffix ?? ""
        func quarantine() -> (text: String, prefixes: [String]) {
            // An ambiguous opener might own unindented later records (PEM/quoted secrets).
            // Only a fresh StreamState can release this fail-closed state, never guest text.
            continuation = Continuation(pending: nil, prefixes: [], commandSuffix: "", quarantined: true)
            return (quarantineMarker, [])
        }
        guard continuation?.quarantined != true else { return quarantine() }
        let text = TerminalControlGrammar.prepare(line, pending: &pending, commandSuffix: &commandSuffix)
        guard let readings = projections(in: text, prefixes: prefixes) else { return quarantine() }
        continuation = pending.map { command in
            let suffixes = readings.map { reading in
                let scalars = reading.text.unicodeScalars
                let end = scalars.lastIndex(where: { $0 != "\r" && $0 != "\n" })
                    .map { scalars.index(after: $0) } ?? scalars.startIndex
                // Option names permit arbitrarily long identifier prefixes. Preserve the
                // structural dash plus their bounded suffix, not a misleading bare word.
                // This is scan-only evidence; omitted option bytes never become output.
                if let option = reading.text[..<end].firstMatch(of: #/(?:^|[^A-Za-z0-9_\/-])(--?[A-Za-z0-9_-]{64,})$/#) {
                    return "--" + option.1.suffix(62)
                }
                return String(String.UnicodeScalarView(scalars[..<end].suffix(64)))
            }
            return Continuation(pending: command, prefixes: Array(Set(suffixes)).sorted(), commandSuffix: commandSuffix)
        }
        return (text, prefixes)
    }
}
