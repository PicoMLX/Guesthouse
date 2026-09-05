import Foundation
import RegexBuilder

/// Removes secrets from text before it can reach a log, the GUI, or a diagnostics export.
///
/// MVP-PLAN.md §3 ("Local storage"): private keys, tokens, device codes, authorization
/// headers, and raw authentication output must never be persisted or exported. The redactor
/// errs on the side of removing too much; over-redaction costs a little debuggability,
/// under-redaction leaks a credential.
///
/// Each removed secret is replaced by `[redacted:<kind>]` so a reader can still see what was
/// there and where.
struct Redactor: Sendable {
    /// Carried across `redact(line:state:)` calls so a secret split over many lines is
    /// removed in full.
    struct StreamState: Hashable, Sendable {
        /// Which kind of control string is open, because only an OSC also ends at BEL.
        enum ControlString: Hashable, Sendable {
            case osc
            case other
        }

        struct QuotedValue: Hashable, Sendable {
            let delimiter: Character
            let escapeDepth: Int
            let kind: String
            var singleQuotesAreLiteral = false
            /// A quoted parameter can end without ending the credential fold containing it.
            /// Whole quoted values leave these false so structured siblings remain visible.
            var enclosingAuthorizationFold = false
            var enclosingSecretFold = false
        }

        /// The label of the PEM block being removed, until its matching footer.
        var pemLabel: String?
        /// The previous line was a bare `Authorization:` label; the value follows on this line.
        var expectingAuthorizationValue = false
        /// That label carried no value of its own, so the next line is the value whether it is
        /// indented or not. A header that did carry one folds only over indented lines.
        var authorizationValueIsOnTheNextLine = false
        /// Unlike an empty header, an explicit backslash owns even a header-shaped next line.
        var authorizationValueExplicitlyContinues = false
        /// The previous line was a bare `password:`-style label; the value follows on this line.
        var expectingSecretValue = false
        /// An already-started secret explicitly continues, rather than awaiting its first value.
        var secretValueExplicitlyContinues = false
        /// The previous line labeled a secret and gave a value that may fold onto this one.
        var expectingSecretContinuation = false
        /// The previous line asked for a code but carried none; the value follows on this line.
        var expectingDeviceCode = false
        /// A distinctive token prefix reached a line boundary; payload may continue after it.
        var wrappedTokenKind: String?
        /// Quoted values may wrap without indentation and remain sensitive until the quote closes.
        var quotedValue: QuotedValue?
        /// A terminal control string opened on an earlier line and has not been terminated yet.
        var openControlString: ControlString?

        init() {}
    }

    init() {}

    static func marker(_ kind: String) -> String { "[redacted:\(kind)]" }

    static func mergePendingContexts(from scanned: StreamState, into state: inout StreamState) {
        state.expectingAuthorizationValue = state.expectingAuthorizationValue || scanned.expectingAuthorizationValue
        state.authorizationValueIsOnTheNextLine = state.authorizationValueIsOnTheNextLine || scanned.authorizationValueIsOnTheNextLine
        state.authorizationValueExplicitlyContinues = state.authorizationValueExplicitlyContinues || scanned.authorizationValueExplicitlyContinues
        state.expectingSecretValue = state.expectingSecretValue || scanned.expectingSecretValue
        state.secretValueExplicitlyContinues = state.secretValueExplicitlyContinues || scanned.secretValueExplicitlyContinues
        state.expectingSecretContinuation = state.expectingSecretContinuation || scanned.expectingSecretContinuation
        state.expectingDeviceCode = state.expectingDeviceCode || scanned.expectingDeviceCode
        state.quotedValue = state.quotedValue ?? scanned.quotedValue
        if scanned.quotedValue?.enclosingAuthorizationFold == true { state.quotedValue?.enclosingAuthorizationFold = true }
        if scanned.quotedValue?.enclosingSecretFold == true { state.quotedValue?.enclosingSecretFold = true }
        state.pemLabel = state.pemLabel ?? scanned.pemLabel
        state.wrappedTokenKind = state.wrappedTokenKind ?? scanned.wrappedTokenKind
    }
}
