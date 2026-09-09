/// GUI/backend seam retained from #60 (#19/#112, MVP-PLAN.md §3).
/// Operations end with a terminal event; queries end after their owning reply.
/// A transport failure is not proof that a mutation did not run. Never replay it blindly.
public protocol RuntimeBackend: Sendable {
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error>
}
