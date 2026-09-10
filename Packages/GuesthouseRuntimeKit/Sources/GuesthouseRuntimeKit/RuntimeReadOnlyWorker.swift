import Dispatch
import Foundation
import GuesthouseCore
import Synchronization

/// Process-wide bounded scheduling for read-only probes (#12, MVP-PLAN.md §3).
/// Initialize shared during service setup, outside registration. This is not a command
/// interface, authorization boundary, or cancellation of a blocking OS call.
final class RuntimeReadOnlyWorker: Sendable {
    static let shared = RuntimeReadOnlyWorker()
    static let maximumOutstanding = 4
    struct Ticket: Hashable, Sendable {
        fileprivate let worker: UUID
        fileprivate let sequence: UInt64
    }
    typealias Enqueue = @Sendable (@escaping @Sendable () -> Void) -> Void
    private struct State: Sendable {
        var nextSequence: UInt64 = 0
        var jobs: [UInt64: Job] = [:]
    }
    private let identity = UUID()
    private let state: Mutex<State>
    private let enqueue: Enqueue

    private convenience init() {
        // Synchronous filesystem/OS probes must not occupy Swift's cooperative pool.
        let queue = DispatchQueue(label: "Guesthouse.Runtime.ReadOnly", qos: .utility)
        self.init(enqueue: { queue.async(execute: $0) })
    }

    // Deterministic executor/sequence seam only. Production uses the shared serial queue.
    init(enqueue: @escaping Enqueue, nextSequence: UInt64 = 0) {
        self.enqueue = enqueue
        state = Mutex(State(nextSequence: nextSequence))
    }

    /// Call ONLY inside the authenticated session's bounded gate.commit registration.
    /// No gate reads, scheduling or callbacks here: registration's lock order is gate → worker.
    /// Nil transfers nothing; the caller still owes the supplied reply. A successful ticket
    /// MUST be started outside gate.commit, even if refusal arrives before start.
    func reserve(
        gate: RuntimeSessionGate, reply: RuntimeReplyObligation,
        work: @escaping @Sendable () -> RuntimeEvent
    ) -> Ticket? {
        let job = Job(gate: gate, reply: reply, work: work)
        defer { withExtendedLifetime(job) {} } // Release rejected captures outside the mutex.
        return state.withLock { state in
            guard state.jobs.count < Self.maximumOutstanding else { return nil }
            let (next, overflow) = state.nextSequence.addingReportingOverflow(1)
            guard !overflow else { return nil } // Never reuse a ticket, including at exhaustion.
            let ticket = Ticket(worker: identity, sequence: state.nextSequence)
            state.nextSequence = next
            state.jobs[ticket.sequence] = job
            return ticket
        }
    }

    /// Scheduling only; the production executor never invokes work inline in this callback.
    /// Canceled reservations still drain once. Do not free capacity on reply cancellation:
    /// an unreturned OS read or queued closure still consumes the process-wide bound.
    @discardableResult
    func start(_ ticket: Ticket) -> Bool {
        guard ticket.worker == identity,
              let job = state.withLock({ $0.jobs[ticket.sequence] }), job.schedule() else { return false }
        enqueue { [self, job] in
            job.run()
            let removed = state.withLock { $0.jobs.removeValue(forKey: ticket.sequence) }
            withExtendedLifetime(removed) {} // Captured-owner destruction must stay outside locks.
        }
        return true
    }

    /// Stop registration before taking the bounded job snapshot. Never hold the worker lock
    /// while acquiring the gate or handing replies/canceling the session. The first refusal
    /// stays authoritative. A started read can finish later; its result cannot answer twice.
    func refuse(_ gate: RuntimeSessionGate, with event: RuntimeEvent) {
        gate.refuse(event)
        let refusal = gate.refusal ?? event
        let jobs = state.withLock { $0.jobs.values.filter { $0.gate === gate } }
        for job in jobs { job.cancel(with: refusal) }
    }

    private final class Job: Sendable {
        private struct Phase: Sendable { var scheduled = false; var canceled = false }
        let gate: RuntimeSessionGate
        private let reply: RuntimeReplyObligation
        private let work: @Sendable () -> RuntimeEvent
        private let phase = Mutex(Phase())

        init(gate: RuntimeSessionGate, reply: RuntimeReplyObligation, work: @escaping @Sendable () -> RuntimeEvent) {
            self.gate = gate; self.reply = reply; self.work = work
        }
        func schedule() -> Bool {
            phase.withLock {
                guard !$0.scheduled else { return false }
                $0.scheduled = true
                return true
            }
        }
        func cancel(with event: RuntimeEvent) {
            phase.withLock { $0.canceled = true }
            reply.finish(event)
        }
        func run() {
            // This is the read-start boundary. Refusal before it skips the probe; refusal
            // afterward settles the reply but does not pretend to interrupt synchronous I/O.
            guard phase.withLock({ !$0.canceled }) else { return }
            let result = gate.refusal ?? work()
            reply.finish(gate.refusal ?? result)
        }
    }
}
