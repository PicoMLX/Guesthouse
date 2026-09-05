import Foundation

extension Redactor {
    /// Handles escapes before the error sanitizer normalizes its bounded inspection window.
    /// Unsafe escapes and interior splices remove their surrounding run. Edge styling survives
    /// unless recovering a consumed charset byte or control payload reveals a credential that
    /// ordinary stripping would leave as a fragment. Recovered text is inspected, never emitted.
    static func redactEscapeSplicedRuns(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var runs: [SanitizationRun] = []
        var run = SanitizationRun()
        var index = 0
        while index < scalars.count {
            if let escape = sanitizationEscape(in: scalars, at: index) {
                if let payload = escape.payload {
                    // Remove the entire control string atomically. In particular, a BEL in a
                    // DCS/APC/PM/SOS payload must not detach its remaining text from its opener.
                    run.recovered += String(String.UnicodeScalarView(scalars[payload].filter(sanitizationKeepsScalar)))
                    run.hasRecovery = true
                    // A nested terminal program has more than one possible recovered reading.
                    // Quarantine this bounded display value instead of guessing or emitting a fragment.
                    run.ambiguousRecovery = run.ambiguousRecovery || scalars[payload].contains {
                        $0.value == 27 || (128...159).contains($0.value)
                    }
                } else {
                    run.output += String(String.UnicodeScalarView(scalars[index..<escape.end]))
                    run.redact = run.redact || !escape.safeStyling
                    if let final = escape.recoveredFinal {
                        run.recovered.unicodeScalars.append(final)
                        run.hasRecovery = true
                    }
                }
                // Adjacent controls share the same visible boundary; none can conceal an
                // interior splice by standing between the escape and its neighboring value.
                run.pendingBoundary = run.pendingBoundary || run.lastVisible.map(isSanitizationRunCharacter) == true
                index = escape.end
                continue
            }
            let scalar = scalars[index]
            if !sanitizationKeepsScalar(scalar) {
                // Normalization will remove this byte, including non-ASCII spaces and line
                // breaks. It cannot divide a credential run or hide an escape's adjacency.
                run.output.unicodeScalars.append(scalar)
            } else if scalar == " " {
                runs.append(run)
                run = SanitizationRun()
            } else {
                run.redact = run.redact || (run.pendingBoundary && isSanitizationRunCharacter(scalar))
                run.pendingBoundary = false
                run.output.unicodeScalars.append(scalar)
                run.visible.unicodeScalars.append(scalar)
                run.recovered.unicodeScalars.append(scalar)
                run.lastVisible = scalar
            }
            index += 1
        }
        runs.append(run)
        // Select once against the bounded source and both inspection renderings, including
        // words normalization might assemble. No attacker-provided occurrence can spoof it.
        let corpus = text + runs.map { " " + $0.visible + " " + $0.recovered }.joined()
        var candidate = 0
        var probe: String
        repeat {
            probe = "guesthouseSanitizerFollowingValue\(candidate)"
            candidate += 1
        } while corpus.contains(probe)
        var output = ""
        for (offset, run) in runs.enumerated() {
            if offset > 0 { output += " " }
            let finished = run.finish(following: " " + probe)
            output += finished.text
            if finished.consumesRemainder { break }
        }
        return output
    }

    private struct SanitizationRun {
        var output = ""
        var visible = ""
        var recovered = ""
        var hasRecovery = false
        var ambiguousRecovery = false
        var redact = false
        var pendingBoundary = false
        var lastVisible: Unicode.Scalar?

        func finish(following: String) -> (text: String, consumesRemainder: Bool) {
            if ambiguousRecovery { return (Redactor.marker("spliced-escape"), true) }
            // Reuse the shared credential rules for recovered edge characters. A second,
            // already recognizable credential in this run must not suppress fragment repair.
            let recoveredCredential = hasRecovery && !visible.isEmpty && visible != recovered
                && Redactor().redact(fieldValue: recovered) != recovered
            guard redact || recoveredCredential else { return (output, false) }
            // Removing a label must not detach its following value from the context that
            // protects it, including same-line code fields that do not arm stream state.
            return (Redactor.marker("spliced-escape"), consumesFollowingValue(output, following)
                    || consumesFollowingValue(visible, following) || consumesFollowingValue(recovered, following))
        }

        private func consumesFollowingValue(_ text: String, _ following: String) -> Bool {
            // The absent ordinary suffix asks the shared rules whether this run consumes
            // the next value. The probe is inspected only and never reaches returned output.
            return !Redactor().redact(fieldValue: text + following).hasSuffix(following)
        }
    }

    /// Matches the error sanitizer's scalar normalization; recovery must inspect the same
    /// visible characters, while the helper leaves their original rendering in its output.
    static func sanitizationKeepsScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned,
             .nonspacingMark, .spacingMark, .enclosingMark:
            false
        case .spaceSeparator:
            scalar == " "
        default:
            true
        }
    }

    private struct SanitizationEscape {
        let end: Int
        var payload: Range<Int>?
        var safeStyling = false
        var recoveredFinal: Unicode.Scalar?
    }

    private static func isSanitizationRunCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122, 45, 95: true
        default: false
        }
    }

    /// Each successful parse consumes the whole escape. Control payloads may contain whitespace
    /// and other escape bytes; scanning them once avoids backtracking over attacker input.
    private static func sanitizationEscape(in scalars: [Unicode.Scalar], at start: Int) -> SanitizationEscape? {
        let first = scalars[start].value
        let next = start + 1 < scalars.count ? scalars[start + 1].value : nil
        let control: (length: Int, osc: Bool)?
        switch (first, next) {
        case (27, 93): control = (2, true)
        case (27, 80), (27, 95), (27, 94), (27, 88): control = (2, false)
        case (157, _): control = (1, true)
        case (144, _), (159, _), (158, _), (152, _): control = (1, false)
        default: control = nil
        }
        if let control {
            let payloadStart = start + control.length
            var end = payloadStart
            while end < scalars.count {
                let scalar = scalars[end].value
                if scalar == 156 || (control.osc && scalar == 7) {
                    return SanitizationEscape(end: end + 1, payload: payloadStart..<end)
                }
                if scalar == 27, end + 1 < scalars.count, scalars[end + 1] == "\\" {
                    return SanitizationEscape(end: end + 2, payload: payloadStart..<end)
                }
                end += 1
            }
            return SanitizationEscape(end: end, payload: payloadStart..<end)
        }

        let csi = first == 155 || (first == 27 && next == 91)
        guard csi || first == 27 else { return nil }
        var end = start + (csi && first == 27 ? 2 : 1)
        let parameterStart = end
        if csi {
            while end < scalars.count, (48...63).contains(scalars[end].value) { end += 1 }
        }
        let intermediateStart = end
        while end < scalars.count, (32...47).contains(scalars[end].value) { end += 1 }
        guard end < scalars.count, (csi ? 64...126 : 48...126).contains(scalars[end].value) else { return nil }
        let final = scalars[end]
        let sgr = csi && final == "m" && intermediateStart == end
            && scalars[parameterStart..<intermediateStart].allSatisfy { scalar in
                (48...57).contains(scalar.value) || scalar == ";" || scalar == ":"
            }
        let charset = !csi && end == start + 2
            && (40...43).contains(scalars[start + 1].value) && (final == "B" || final == "0")
        return SanitizationEscape(end: end + 1, safeStyling: sgr || charset, recoveredFinal: charset ? final : nil)
    }
}
