import Synchronization
import XPC

/// Explicit XPC activity for admitted work (MVP-PLAN.md §3, #24).
/// Adapted from the token ownership in retained PR #72; no provider or identity store.
///
/// Apple's documented automatic transaction ends when the reply is sent/released. Swift
/// XPCSession does not give an arbitrary Task a documented lifetime guarantee. Acquire a
/// token before scheduling work and retain it until that work, including cleanup, settles.
/// https://developer.apple.com/documentation/xpc/xpc_transaction_begin()
/// This prevents ordinary idle exit, not crashes, forced termination or power loss.
public struct OperationSupervisor: Sendable {
    public final class Token: Sendable {
        private let ended = Mutex(false)
        private let finish: @Sendable () -> Void

        fileprivate init(finish: @escaping @Sendable () -> Void) { self.finish = finish }

        /// Explicit completion and deinitialization may race; only one ends the transaction.
        public func end() {
            let first = ended.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if first { finish() }
        }

        deinit { end() }
    }

    private let begin: @Sendable () -> Void
    private let finish: @Sendable () -> Void

    public init() { self.init(begin: { xpc_transaction_begin() }, finish: { xpc_transaction_end() }) }

    // In-process test seam only. No request can replace lifecycle policy.
    init(begin: @escaping @Sendable () -> Void, finish: @escaping @Sendable () -> Void) {
        self.begin = begin
        self.finish = finish
    }

    /// One token per admitted operation, or retained supervised process when implemented.
    /// Disconnect/cancellation of the waiter is not evidence that the work has settled.
    public func hold() -> Token {
        begin()
        return Token(finish: finish)
    }
}
