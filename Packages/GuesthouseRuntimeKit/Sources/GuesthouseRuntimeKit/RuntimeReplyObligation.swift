import GuesthouseCore
import Synchronization

/// Retains one ALREADY counted reply for a future bounded worker (#12, MVP-PLAN.md §3).
/// The caller must own one successful gate.began(), retain this object, and explicitly finish
/// it on every path. This does not admit work, create a native context, or cancel on deinit.
/// A worker registry must settle/remove every obligation before releasing its session owner.
final class RuntimeReplyObligation: Sendable {
    private struct Pending: Sendable {
        let gate: RuntimeSessionGate
        let answer: @Sendable (RuntimeEvent) -> Void
        let cancel: @Sendable () -> Void
    }
    private let pending: Mutex<Pending?>

    init(
        gate: RuntimeSessionGate,
        answer: @escaping @Sendable (RuntimeEvent) -> Void,
        cancel: @escaping @Sendable () -> Void
    ) {
        pending = Mutex(Pending(gate: gate, answer: answer, cancel: cancel))
    }

    /// Only the winner answers and balances accounting. `answer` must complete explicit
    /// handoff (or handle its send/encoding failure) before returning; it must not enqueue
    /// a later send. No callback runs under this mutex or the session gate's mutex.
    /// A duplicate returns false even while the winning answer is still executing.
    @discardableResult
    func finish(_ event: RuntimeEvent) -> Bool {
        let obligation = pending.withLock { value -> Pending? in
            defer { value = nil }
            return value
        }
        guard let obligation else { return false }
        // Clearing pending also releases captured context/session owners after this call,
        // even if a late completion source still retains the now-settled obligation.
        defer { if obligation.gate.finished() { obligation.cancel() } }
        obligation.answer(event)
        return true
    }
}
