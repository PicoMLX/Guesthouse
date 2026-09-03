/// Shared models, typed contracts, state machines, parsers, and other testable logic
/// used by both the Guesthouse GUI and the GuesthouseRuntime XPC service.
///
/// This package performs no process execution and no host operations; those live in the
/// runtime service. See `AGENTS.md` and `MVP-PLAN.md` §3.
public enum CoreInfo: Sendable {
    /// Identifies this module in diagnostics and version reports.
    public static let moduleName = "GuesthouseCore"
}
