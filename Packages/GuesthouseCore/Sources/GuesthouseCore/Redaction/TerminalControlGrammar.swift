import Foundation
import RegexBuilder

/// Scalar-level control framing, not a terminal emulator. It never executes commands or
/// interprets a control-string payload as visible text. Stream state has constant size.
enum TerminalControlGrammar {
    enum Pending: Hashable, Sendable {
        case osc, other, csi
        case escape(intermediate: Bool)
    }

    // Regex values are immutable but not Sendable; only this immutable container is shared.
    private struct Patterns: @unchecked Sendable {
        let escape: Regex<Substring>
        let unfinishedCSI: Regex<Substring>
        let unfinishedEscape: Regex<Substring>
        let unfinishedOSC: Regex<Substring>
        let unfinishedOther: Regex<Substring>
        let stringEnd: Regex<Substring>
        let oscEnd: Regex<Substring>

        init() {
            // Keep physical CR/LF framing outside CSI/ESC bodies. Other executable C0 bytes
            // and DEL do not leave the escape/CSI state. CAN/SUB and a fresh ESC cancel it.
            let ignored = #/[\u{00}-\u{09}\u{0B}\u{0C}\u{0E}-\u{17}\u{19}\u{1C}-\u{1F}\u{7F}]/#
            let esc = Regex { "\u{1B}"; ZeroOrMore { ignored } }
            let oscStart = Regex { ChoiceOf { Regex { esc; "]" }; "\u{9D}" } }
            let otherStart = Regex { ChoiceOf { Regex { esc; #/[P_^X]/# }; #/[\u{90}\u{9F}\u{9E}\u{98}]/# } }
            let csiStart = Regex { ChoiceOf { Regex { esc; "[" }; "\u{9B}" } }
            let csiBody = Regex { ZeroOrMore { ChoiceOf { ignored; #/[ -?]/# } } }
            let escBody = Regex { ZeroOrMore { ChoiceOf { ignored; #/[ -\/]/# } } }
            let abort = Regex { Lookahead { ChoiceOf { "\u{1B}"; Anchor.endOfSubject } } }
            let st = Regex { esc; "\\" }
            let oscPayload = #/[^\u{07}\u{18}\u{1A}\u{9C}\u{1B}]*/#
            let otherPayload = #/[^\u{18}\u{1A}\u{9C}\u{1B}]*/#
            escape = Regex {
                ChoiceOf {
                    Regex { oscStart; oscPayload; Optionally { ChoiceOf { #/[\u{07}\u{18}\u{1A}\u{9C}]/#; st } } }
                    Regex { otherStart; otherPayload; Optionally { ChoiceOf { #/[\u{18}\u{1A}\u{9C}]/#; st } } }
                    Regex { csiStart; csiBody; ChoiceOf { #/[\u{18}\u{1A}@-~]/#; abort } }
                    Regex { esc; escBody; ChoiceOf { #/[\u{18}\u{1A}0-~]/#; abort } }
                    #/[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}\u{7F}-\u{9F}]/#
                }
            }.matchingSemantics(.unicodeScalar)
            unfinishedCSI = Regex { csiStart; csiBody; Anchor.endOfSubject }.matchingSemantics(.unicodeScalar)
            unfinishedEscape = Regex { esc; escBody; Anchor.endOfSubject }.matchingSemantics(.unicodeScalar)
            unfinishedOSC = Regex { oscStart; oscPayload; Anchor.endOfSubject }.matchingSemantics(.unicodeScalar)
            unfinishedOther = Regex { otherStart; otherPayload; Anchor.endOfSubject }.matchingSemantics(.unicodeScalar)
            stringEnd = Regex { ChoiceOf { #/[\u{18}\u{1A}\u{9C}]/#; st; Lookahead { "\u{1B}" } } }.matchingSemantics(.unicodeScalar)
            oscEnd = Regex { ChoiceOf { #/[\u{07}\u{18}\u{1A}\u{9C}]/#; st; Lookahead { "\u{1B}" } } }.matchingSemantics(.unicodeScalar)
        }
    }

    private static let patterns = Patterns()
    static var escape: Regex<Substring> { patterns.escape }

    static func normalize(_ text: String) -> String { text.replacing(escape, with: "") }

    /// Returns a physical record suitable for the evidence renderer. Incomplete control
    /// suffixes cannot become fake field values. For a continued command only its parser
    /// class is retained, never an unbounded parameter or payload buffer. Synthetic control
    /// prefixes are consumed by the same grammar and cannot become visible text.
    static func prepare(_ line: String, pending: inout Pending?) -> String {
        var text = line
        switch pending {
        case .osc, .other:
            let end = pending == .osc ? patterns.oscEnd : patterns.stringEnd
            guard let terminator = text.firstMatch(of: end) else { return "" }
            text = String(text[terminator.range.upperBound...])
        case .csi:
            text = "\u{1B}[" + text
        case .escape(let intermediate):
            text = (intermediate ? "\u{1B}(" : "\u{1B}") + text
        case nil: break
        }
        pending = nil
        // Never discover a nested introducer by rescanning an already consumed payload.
        guard let last = text.matches(of: escape).last, last.range.upperBound == text.endIndex else { return text }
        if last.0.wholeMatch(of: patterns.unfinishedOSC) != nil { pending = .osc }
        else if last.0.wholeMatch(of: patterns.unfinishedOther) != nil { pending = .other }
        else if last.0.wholeMatch(of: patterns.unfinishedCSI) != nil { pending = .csi }
        else if last.0.wholeMatch(of: patterns.unfinishedEscape) != nil {
            pending = .escape(intermediate: last.0.unicodeScalars.contains { (0x20...0x2F).contains($0.value) })
        }
        return pending == nil ? text : String(text[..<last.range.lowerBound])
    }
}

