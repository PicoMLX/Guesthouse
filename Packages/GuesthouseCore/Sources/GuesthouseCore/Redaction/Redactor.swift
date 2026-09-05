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
public struct Redactor: Sendable {
    /// Carried across `redact(line:state:)` calls so a secret split over many lines is
    /// removed in full.
    public struct StreamState: Hashable, Sendable {
        /// Which kind of control string is open, because only an OSC also ends at BEL.
        enum ControlString: Hashable, Sendable {
            case osc
            case other
        }

        struct QuotedValue: Hashable, Sendable {
            let delimiter: Character
            let escapeDepth: Int
            let kind: String
        }

        /// The label of the PEM block being removed, until its matching footer.
        var pemLabel: String?
        /// The previous line was a bare `Authorization:` label; the value follows on this line.
        var expectingAuthorizationValue = false
        /// That label carried no value of its own, so the next line is the value whether it is
        /// indented or not. A header that did carry one folds only over indented lines.
        var authorizationValueIsOnTheNextLine = false
        /// The previous line was a bare `password:`-style label; the value follows on this line.
        var expectingSecretValue = false
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

        public init() {}
    }

    public init() {}

    static func marker(_ kind: String) -> String { "[redacted:\(kind)]" }

    static func mergePendingContexts(from scanned: StreamState, into state: inout StreamState) {
        state.expectingAuthorizationValue = state.expectingAuthorizationValue || scanned.expectingAuthorizationValue
        state.authorizationValueIsOnTheNextLine = state.authorizationValueIsOnTheNextLine || scanned.authorizationValueIsOnTheNextLine
        state.expectingSecretValue = state.expectingSecretValue || scanned.expectingSecretValue
        state.expectingSecretContinuation = state.expectingSecretContinuation || scanned.expectingSecretContinuation
        state.expectingDeviceCode = state.expectingDeviceCode || scanned.expectingDeviceCode
        state.quotedValue = state.quotedValue ?? scanned.quotedValue
        state.pemLabel = state.pemLabel ?? scanned.pemLabel
        state.wrappedTokenKind = state.wrappedTokenKind ?? scanned.wrappedTokenKind
    }
}
