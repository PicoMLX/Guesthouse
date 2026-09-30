/// GUI/backend seam retained from #60 (#19/#112, MVP-PLAN.md §3).
/// Operations end with a terminal event; queries end after their owning reply.
/// A transport failure is not proof that a mutation did not run. Never replay it blindly.
public protocol RuntimeBackend: Sendable {
    /// One app-owned consumer for this backend's lifetime. At most the latest cause is buffered;
    /// notifications can coalesce and are invalidation signals, not a history or readiness proof.
    /// Invalidate cached status even when no request is pending. Never automatically replay work.
    /// Canceling the observer ends observation; create a new backend to establish a new observer.
    var connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause> { get }

    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error>
}
