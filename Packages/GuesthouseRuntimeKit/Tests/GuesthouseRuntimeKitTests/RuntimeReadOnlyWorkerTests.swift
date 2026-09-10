import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Deterministic scheduling/ownership tests, not live OS-read or hardware evidence.
@Suite(.timeLimit(.minutes(1))) struct RuntimeReadOnlyWorkerTests {
    private final class Executor: Sendable {
        let pending = Mutex<[@Sendable () -> Void]>([])
        func enqueue(_ work: @escaping @Sendable () -> Void) { pending.withLock { $0.append(work) } }
        func runOne() {
            let work = pending.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            work?() // Never execute a callback under the executor's bookkeeping mutex.
        }
        func drain() { while pending.withLock({ !$0.isEmpty }) { runOne() } }
    }
    private final class Trace: Sendable {
        struct State: Sendable { var runs = 0; var replies: [RuntimeEvent] = []; var cancels = 0; var released = false }
        let state = Mutex(State())
        let success = RuntimeEvent.completed(OperationID())
        func run() -> RuntimeEvent { state.withLock { $0.runs += 1 }; return success }
    }
    private final class Sentinel: Sendable {
        let trace: Trace
        init(_ trace: Trace) { self.trace = trace }
        deinit { trace.state.withLock { $0.released = true } }
    }
    private final class Call: Sendable {
        let gate: RuntimeSessionGate
        let trace: Trace
        let reply: RuntimeReplyObligation
        init(gate: RuntimeSessionGate = RuntimeSessionGate()) throws {
            self.gate = gate
            let trace = Trace()
            self.trace = trace
            _ = try #require(gate.began())
            reply = RuntimeReplyObligation(gate: gate, answer: { event in
                trace.state.withLock { $0.replies.append(event) }
            }, cancel: { trace.state.withLock { $0.cancels += 1 } })
        }
        func reserve(_ worker: RuntimeReadOnlyWorker, work: (@Sendable () -> RuntimeEvent)? = nil) -> RuntimeReadOnlyWorker.Ticket? {
            let probe: @Sendable () -> RuntimeEvent = work ?? { [trace] in trace.run() }
            var ticket: RuntimeReadOnlyWorker.Ticket?
            _ = gate.commit(.runtimeVersion) { _ in
                ticket = worker.reserve(gate: gate, reply: reply, work: probe)
                return trace.success // Test registration marker, not a delivered reply.
            }
            return ticket
        }
        func reject() { reply.finish(.failed(OperationID(), .invalidRequest(.tooManyInFlight))) }
    }

    @Test func registrationDoesNotScheduleOrRunAndStartingIsExactlyOnce() throws {
        let executor = Executor()
        let worker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let call = try Call(), ticket = try #require(call.reserve(worker))
        #expect(executor.pending.withLock { $0.isEmpty })
        #expect(call.trace.state.withLock { $0.runs == 0 && $0.replies.isEmpty })
        #expect(worker.start(ticket))
        #expect(!worker.start(ticket))
        #expect(executor.pending.withLock { $0.count } == 1)
        #expect(call.trace.state.withLock { $0.runs } == 0)
        executor.drain()
        #expect(call.trace.state.withLock { $0.runs } == 1)
        #expect(call.trace.state.withLock { $0.replies } == [call.trace.success])
        #expect(!worker.start(ticket))
        let count = try #require(call.gate.began())
        #expect(count == 0)
        #expect(!call.gate.finished())
    }

    @Test func admissionIsBoundedAcrossDifferentSessionsAndRejectionTransfersNothing() throws {
        let executor = Executor()
        let worker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let calls = try (0..<4).map { _ in try Call() }
        let tickets = try calls.map { try #require($0.reserve(worker)) }
        let rejected = try Call()
        #expect(rejected.reserve(worker) == nil)
        #expect(rejected.trace.state.withLock { $0.replies.isEmpty && $0.runs == 0 })
        #expect(executor.pending.withLock { $0.isEmpty })
        rejected.reject() // No ownership was transferred; the caller must still answer.
        for ticket in tickets { #expect(worker.start(ticket)) }
        executor.drain()
        for call in calls { #expect(call.trace.state.withLock { $0.replies } == [call.trace.success]) }
        let next = try Call(), nextTicket = try #require(next.reserve(worker))
        #expect(worker.start(nextTicket))
        executor.drain()
    }

    @Test func refusalBeforeStartSettlesRepliesButKeepsCanceledReservationsBounded() throws {
        let executor = Executor(), gate = RuntimeSessionGate()
        let worker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let calls = try (0..<4).map { _ in try Call(gate: gate) }
        let tickets = try calls.map { try #require($0.reserve(worker)) }
        let refusal = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        worker.refuse(gate, with: refusal)
        worker.refuse(gate, with: .failed(OperationID(), .invalidRuntimeReply(.malformed)))
        for call in calls { #expect(call.trace.state.withLock { $0.replies } == [refusal]) }
        #expect(calls.reduce(0) { $0 + $1.trace.state.withLock { $0.cancels } } == 1)
        #expect(gate.began() == nil)
        let rejected = try Call()
        #expect(rejected.reserve(worker) == nil)
        rejected.reject()
        for ticket in tickets { #expect(worker.start(ticket)) }
        #expect(executor.pending.withLock { $0.count } == 4)
        executor.drain()
        #expect(calls.allSatisfy { $0.trace.state.withLock { $0.runs == 0 } })
        let next = try Call(), nextTicket = try #require(next.reserve(worker))
        #expect(worker.start(nextTicket))
        executor.drain()
        #expect(next.trace.state.withLock { $0.runs } == 1)
    }

    @Test func refusalDuringAReadDoesNotFreeItsSlotOrDeliverItsLateResult() throws {
        let executor = Executor()
        let worker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let running = try Call(), premature = try Call(), later = try Call()
        let others = try (0..<3).map { _ in try Call() }
        let refusal = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        let ticket = try #require(running.reserve(worker, work: {
            _ = running.trace.run()
            worker.refuse(running.gate, with: refusal)
            #expect(running.trace.state.withLock { $0.replies } == [refusal])
            #expect(premature.reserve(worker) == nil) // The read has not returned yet.
            premature.reject()
            return running.trace.success
        }))
        let otherTickets = try others.map { try #require($0.reserve(worker)) }
        #expect(worker.start(ticket))
        executor.runOne()
        #expect(running.trace.state.withLock { $0.replies } == [refusal])
        #expect(running.trace.state.withLock { $0.runs == 1 && $0.cancels == 1 })
        let laterTicket = try #require(later.reserve(worker))
        for next in otherTickets + [laterTicket] { #expect(worker.start(next)) }
        executor.drain()
        #expect(later.trace.state.withLock { $0.replies } == [later.trace.success])
    }

    @Test func refusingOneSessionDoesNotCancelAnotherSessionsRead() throws {
        let executor = Executor()
        let worker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let first = try Call(), second = try Call()
        let one = try #require(first.reserve(worker)), two = try #require(second.reserve(worker))
        let refusal = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        worker.refuse(first.gate, with: refusal)
        #expect(second.trace.state.withLock { $0.replies.isEmpty && $0.cancels == 0 })
        #expect(worker.start(one))
        #expect(worker.start(two))
        executor.drain()
        #expect(first.trace.state.withLock { $0.runs } == 0)
        #expect(second.trace.state.withLock { $0.replies } == [second.trace.success])
    }

    @Test func ticketsDoNotAliasAcrossWorkersOrAfterCompletion() throws {
        let executor = Executor()
        let firstWorker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let secondWorker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let first = try Call(), second = try Call(), later = try Call()
        let firstTicket = try #require(first.reserve(firstWorker))
        let secondTicket = try #require(second.reserve(secondWorker))
        #expect(!firstWorker.start(secondTicket))
        #expect(!secondWorker.start(firstTicket))
        #expect(firstWorker.start(firstTicket))
        #expect(secondWorker.start(secondTicket))
        executor.drain()
        let laterTicket = try #require(later.reserve(firstWorker))
        #expect(laterTicket != firstTicket)
        #expect(!firstWorker.start(firstTicket))
        #expect(firstWorker.start(laterTicket))
        executor.drain()
        #expect(later.trace.state.withLock { $0.runs } == 1)
    }

    @Test func exhaustedTicketSequenceRefusesWithoutWrappingOrTakingReply() throws {
        let executor = Executor()
        let worker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) }, nextSequence: .max)
        let call = try Call()
        #expect(call.reserve(worker) == nil)
        #expect(call.trace.state.withLock { $0.replies.isEmpty && $0.runs == 0 })
        #expect(executor.pending.withLock { $0.isEmpty })
        call.reject()
    }

    @Test func drainedWorkReleasesItsCaptureWhileWorkerAndTicketRemainAlive() throws {
        let executor = Executor()
        let worker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let call = try Call()
        let ticket = try #require(reservingSentinel(call, worker: worker))
        #expect(!call.trace.state.withLock { $0.released })
        #expect(worker.start(ticket))
        executor.drain()
        withExtendedLifetime((worker, ticket)) {
            #expect(call.trace.state.withLock { $0.released })
        }
    }

    private func reservingSentinel(_ call: Call, worker: RuntimeReadOnlyWorker) -> RuntimeReadOnlyWorker.Ticket? {
        let sentinel = Sentinel(call.trace)
        return call.reserve(worker, work: { [sentinel] in
            withExtendedLifetime(sentinel) { call.trace.run() }
        })
    }

    @Test func competingSessionsCannotOverbookTheWorker() async throws {
        let executor = Executor()
        let worker = RuntimeReadOnlyWorker(enqueue: { executor.enqueue($0) })
        let calls = try (0..<32).map { _ in try Call() }
        let accepted = await withTaskGroup(of: (Int, RuntimeReadOnlyWorker.Ticket?).self) { group in
            for (index, call) in calls.enumerated() { group.addTask { (index, call.reserve(worker)) } }
            var tickets: [RuntimeReadOnlyWorker.Ticket] = []
            for await (index, ticket) in group {
                if let ticket { tickets.append(ticket) } else { calls[index].reject() }
            }
            return tickets
        }
        #expect(accepted.count == 4)
        for ticket in accepted { #expect(worker.start(ticket)) }
        executor.drain()
        #expect(calls.allSatisfy { $0.trace.state.withLock { $0.replies.count == 1 } })
        #expect(calls.reduce(0) { $0 + $1.trace.state.withLock { $0.runs } } == 4)
    }
}
