import Foundation

extension SanitizedText {
    /// Values that can originate outside the app (CLI output, guest responses, file names)
    /// are redacted, normalized, scanned again, and bounded before interpolation. Error
    /// messages and encoded values share this single-line display-value policy.
    ///
    /// Both scans matter: control whitespace can delimit a credential, while normalization
    /// can also assemble a control-split token. Neither reading can discard the other's evidence.
    /// The bound is in Unicode scalars, so combining marks cannot hide behind one `Character`.
    /// Input is bounded before any work: only the first `limit + lookahead` scalars are
    /// normalized and redacted, so an oversized value costs a bounded amount of memory and CPU.
    /// Credentials can exceed this finite lookahead. The repairs below therefore remove
    /// recognized open credential forms and normalization-shortened fragments at the cut,
    /// without assuming that the entire credential fits inside the inspection window.
    static let sanitizeLookahead = 512

    static func sanitize(_ value: String, limit: Int = 80) -> String {
        // Public entry points use this policy, so clamp the bound: an extreme limit
        // would otherwise overflow the window arithmetic and a negative one would hand
        // `prefix` an invalid length, trapping instead of returning sanitized text.
        let limit = min(max(limit, 1), SanitizedText.maximumLimit)
        // Only the window plus one scalar is ever looked at, so the cost is independent of the
        // input's size.
        let (window, truncated) = Self.inspectionWindow(value.unicodeScalars, maximum: limit + Self.sanitizeLookahead)
        // At the cut, a colon-bearing value may be a DSN whose transport is outside our budget;
        // a Basic fragment may no longer decode. Their unknown remainder cannot prove safety.
        // A whole open URL authority already has the explicit userinfo cutoff repair below.
        let openAuthority = window.wholeMatch(of: #/[A-Za-z][A-Za-z0-9+.-]*:(?:\\?\/){2}[^\s\/?#]*$/#) != nil
        let ambiguousCut = truncated && ((window.contains(":") && !openAuthority)
            || window.contains(#/(?:^|[^A-Za-z0-9])(?i:Basic)[ \t]+[A-Za-z0-9+\/=]*$/#))
        let bounded = ambiguousCut ? Redactor.marker("truncated") : window
        // Complete escape sequences go first, so styling inside a token cannot leave a
        // fragment behind once the bare control scalars are dropped. A sequence that can only
        // have borrowed its terminator from the value goes further and takes its whole run
        // with it, because stripping it would silently repair a credential into something the
        // patterns below no longer recognize. Combining marks go too: a mark inside a token
        // would otherwise split it out of the redactor's reach.
        let spliceSafe = Redactor.redactEscapeSplicedRuns(bounded)
        let originalStripped = Redactor.stripTerminalEscapes(spliceSafe)
        let joined = String(String.UnicodeScalarView(originalStripped.unicodeScalars.filter(Redactor.sanitizationKeepsScalar)))
        let normalizationShortened = joined.unicodeScalars.count < limit + Self.sanitizeLookahead
        let credentialReading = String(String.UnicodeScalarView(spliceSafe.unicodeScalars.map {
            CharacterSet.whitespacesAndNewlines.contains($0) ? " " : $0
        }))
        let rawRedacted = Redactor().redact(fieldValue: credentialReading)
        let stripped = Redactor.stripTerminalEscapes(rawRedacted)
        let joinedRedacted = Redactor().redact(fieldValue: joined)
        var normalized = rawRedacted == credentialReading ? joinedRedacted
            : Redactor().redact(fieldValue: String(String.UnicodeScalarView(stripped.unicodeScalars.filter(Redactor.sanitizationKeepsScalar))))
        // A raw scan may replace a prefix before normalization assembles its secret suffix.
        // Neither transformed string retains offsets into the other. If the normalized reading
        // finds credential evidence and disagrees, quarantine this bounded display value whole.
        if joinedRedacted != joined, joinedRedacted != normalized {
            normalized = Redactor.marker("normalized-value")
        }
        if truncated {
            // Normalization drops scalars, so a window full of raw input can normalize to far
            // less: a run of combining marks between a device code's first and last character
            // pushes that last character out of the window and leaves `AB12-CD3`, which no
            // pattern recognizes. Whenever the window was cut and normalization shortened it,
            // the run at the cut is a fragment of something unknown and does not survive. A
            // value that was only long, not padded, keeps the whole window and the two repairs
            // below.
            if normalizationShortened {
                normalized = normalized.replacing(#/\S+$/#, with: Redactor.marker("truncated"))
            }
            // A URL authority still open at the cut may be userinfo whose terminating `@` fell
            // outside the window: treat the whole remainder as a credential. The delimiter is
            // recognized in both the spellings the redactor's own userinfo rule accepts, since a
            // URL that reached a log through JSON keeps that encoding's escaped slashes, and is
            // put back exactly as it came in.
            normalized = normalized.replacing(#/((?::|^|[\s\u{001F}"'(<\[{]|(?:^|[\s\u{001F}"'(<\[{])(?:--?)?[A-Za-z][A-Za-z0-9_.-]*[ \t]*=[ \t]*)(?:\\?\/){2})[^\s\/?#]*$/#) { match in "\(match.1)\(Redactor.marker("userinfo"))" }
            // A JWT whose payload is longer than the window loses the second `.` the redactor
            // matches on, so a token that began inside the visible prefix would be emitted in
            // the clear. A JOSE header followed by a segment running to the cut is one. The
            // header search is shared with `redactedJWT`: an untrusted name concatenated in
            // front of the token is inside the segment this rule captures. Asking only about
            // that entire segment would miss the embedded JOSE header.
            normalized = normalized.replacing(#/\b([A-Za-z0-9_-]{4,})\.[A-Za-z0-9_-]*$/#) { match in
                guard let start = Redactor.joseHeaderStart(match.1) else { return String(match.0) }
                return match.1[..<start] + Redactor.marker("jwt")
            }
        }
        let redacted = Redactor().redact(fieldValue: normalized)
        let scalars = redacted.unicodeScalars
        guard scalars.count > limit else { return redacted }
        return String(String.UnicodeScalarView(scalars.prefix(limit))) + "…"
    }

    /// Materializes only the inspection budget plus one sentinel scalar. A sequence input
    /// makes the read budget testable without wall-clock assumptions about the CI machine.
    static func inspectionWindow<S: Sequence>(
        _ scalars: S, maximum: Int
    ) -> (value: String, truncated: Bool) where S.Element == Unicode.Scalar {
        let window = Array(scalars.prefix(maximum + 1))
        return (String(String.UnicodeScalarView(window.prefix(maximum))), window.count > maximum)
    }
}
