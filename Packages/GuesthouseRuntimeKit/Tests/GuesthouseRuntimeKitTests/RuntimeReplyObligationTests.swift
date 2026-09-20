import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Accounting only. The existing native-handler suite covers actual context/send failures.
@Suite(.timeLimit(.minutes(1))) struct RuntimeReplyObligationTests {
    private enum Step: Equatable, Sendable { case answer, returning, canceled, released }
    private final class Trace: Sendable {
        let steps = Mutex<[Step]>([])
        let events = Mutex<[RuntimeEvent]>([])
        func add(_ step: Step) { steps.withLock { $0.append(step) } }
        func record(_ event: RuntimeEvent) {
            events.withLock { $0.append(event) }
            add(.answer)
        }
    }
    private final class Slot: Sendable {
        let value = Mutex<RuntimeReplyObligation?>(nil)
    }
    private final class Sentinel: Sendable {
        let trace: Trace
        init(_ trace: Trace) { self.trace = trace }
        deinit { trace.add(.released) }
    }

    @Test func exactlyOneFinishBalancesAnAlreadyCountedCallback() throws {
        let gate = RuntimeSessionGate(), trace = Trace()
        let initial = try #require(gate.began())
        #expect(initial == 0)
        let reply = RuntimeReplyObligation(gate: gate, answer: { trace.record($0) }, cancel: { trace.add(.canceled) })
        // Construction does not call began again, and an unsettled reply remains counted.
        let whilePending = try #require(gate.began())
        #expect(whilePending == 1)
        #expect(!gate.finished()) // Balance just the synthetic second callback.
        let event = RuntimeEvent.completed(OperationID())
        #expect(reply.finish(event))
        #expect(!reply.finish(.completed(OperationID())))
        #expect(trace.events.withLock { $0 } == [event])
        #expect(trace.steps.withLock { $0 } == [.answer])
        let afterFinishing = try #require(gate.began())
        #expect(afterFinishing == 0)
        #expect(!gate.finished())
    }

    @Test func refusedSessionCancelsOnlyAfterItsAnswerReturns() throws {
        let gate = RuntimeSessionGate(), trace = Trace()
        _ = try #require(gate.began())
        let reply = RuntimeReplyObligation(gate: gate, answer: { event in
            trace.record(event)
            #expect(gate.began() == nil)
            #expect(trace.steps.withLock { $0 } == [.answer])
            trace.add(.returning)
        }, cancel: { trace.add(.canceled) })
        let refusal = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        gate.refuse(refusal)
        #expect(reply.finish(refusal))
        #expect(!reply.finish(refusal))
        #expect(trace.steps.withLock { $0 } == [.answer, .returning, .canceled])
        #expect(trace.events.withLock { $0 } == [refusal])
    }

    @Test func allAlreadyCountedAnswersDrainBeforeOneCancel() throws {
        let gate = RuntimeSessionGate(), trace = Trace()
        _ = try #require(gate.began())
        _ = try #require(gate.began())
        let first = RuntimeReplyObligation(gate: gate, answer: { trace.record($0) }, cancel: { trace.add(.canceled) })
        let second = RuntimeReplyObligation(gate: gate, answer: { trace.record($0) }, cancel: { trace.add(.canceled) })
        let refusal = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        gate.refuse(refusal)
        #expect(first.finish(refusal))
        #expect(trace.steps.withLock { $0 } == [.answer])
        #expect(!first.finish(refusal))
        #expect(second.finish(refusal))
        #expect(!second.finish(refusal))
        #expect(trace.steps.withLock { $0 } == [.answer, .answer, .canceled])
    }

    @Test func anotherCompletionCannotCancelAnAnswerStillExecuting() throws {
        let gate = RuntimeSessionGate(), trace = Trace()
        _ = try #require(gate.began())
        _ = try #require(gate.began())
        let second = RuntimeReplyObligation(gate: gate, answer: { trace.record($0) }, cancel: { trace.add(.canceled) })
        let first = RuntimeReplyObligation(gate: gate, answer: { event in
            trace.record(event)
            #expect(second.finish(event))
            // Both callbacks have claimed their answers, but the first still owes handoff.
            #expect(trace.steps.withLock { $0 } == [.answer, .answer])
            trace.add(.returning)
        }, cancel: { trace.add(.canceled) })
        let refusal = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        gate.refuse(refusal)
        #expect(first.finish(refusal))
        #expect(trace.steps.withLock { $0 } == [.answer, .answer, .returning, .canceled])
        #expect(!second.finish(refusal))
    }

    @Test func reentrantAnswerAndCancelCannotFinishAgainOrDeadlock() throws {
        let gate = RuntimeSessionGate(), trace = Trace(), slot = Slot()
        _ = try #require(gate.began())
        let refusal = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        let reply = RuntimeReplyObligation(gate: gate, answer: { event in
            trace.record(event)
            let sameReply = slot.value.withLock { $0 }
            #expect(sameReply?.finish(event) == false)
            gate.refuse(refusal)
            trace.add(.returning)
        }, cancel: {
            let sameReply = slot.value.withLock { $0 }
            #expect(sameReply?.finish(refusal) == false)
            #expect(gate.began() == nil)
            trace.add(.canceled)
        })
        slot.value.withLock { $0 = reply }
        #expect(reply.finish(.completed(OperationID())))
        #expect(trace.steps.withLock { $0 } == [.answer, .returning, .canceled])
        #expect(trace.events.withLock { $0.count } == 1)
    }

    @Test func competingCompletionsHaveOneAnswerAndOneCancel() async throws {
        let gate = RuntimeSessionGate(), trace = Trace()
        _ = try #require(gate.began())
        let reply = RuntimeReplyObligation(gate: gate, answer: { trace.record($0) }, cancel: { trace.add(.canceled) })
        gate.refuse(.failed(OperationID(), .unauthorizedCaller))
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<32 { group.addTask { reply.finish(.completed(OperationID())) } }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        #expect(winners == 1)
        #expect(trace.events.withLock { $0.count } == 1)
        #expect(trace.steps.withLock { $0 } == [.answer, .canceled])
        #expect(gate.began() == nil)
    }

    @Test func settledObligationDoesNotRetainItsAnswerCapture() throws {
        let gate = RuntimeSessionGate(), trace = Trace()
        _ = try #require(gate.began())
        let reply = retainingSentinel(gate: gate, trace: trace)
        #expect(trace.steps.withLock { $0.isEmpty })
        #expect(reply.finish(.completed(OperationID())))
        withExtendedLifetime(reply) {
            #expect(trace.steps.withLock { $0 } == [.answer, .released])
        }
    }

    private func retainingSentinel(gate: RuntimeSessionGate, trace: Trace) -> RuntimeReplyObligation {
        let sentinel = Sentinel(trace)
        return RuntimeReplyObligation(gate: gate, answer: { [sentinel] event in
            withExtendedLifetime(sentinel) { trace.record(event) }
        }, cancel: { trace.add(.canceled) })
    }
}
