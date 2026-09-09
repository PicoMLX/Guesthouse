import Dispatch
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseClientKit

@Suite(.timeLimit(.minutes(1))) struct RuntimeClientInboxTests {
    static let id = OperationID(), environment = EnvironmentID()
    static let traffic: [RuntimeEvent] = [
        .progress(id, .init(kind: .copying)),
        .diagnostic(.init(operation: .startEnvironment, outcome: .started, operationID: id.uuid)),
        .status(.init(environmentID: environment, vm: .running, readiness: .checking)),
    ]

    @Test(arguments: traffic)
    func progressFloodCannotConsumeOwningReplyOrEndSlots(traffic: RuntimeEvent) throws {
        let inbox = RuntimeClientInbox()
        let fixtures = try (0..<RuntimeClientInbox.requestLimit).map { _ in try reserve(inbox) }
        for _ in 0..<10_000 { inbox.incoming(traffic) }
        for fixture in fixtures {
            inbox.replied(fixture.key, .success(.accepted(Self.id)))
            inbox.ended(fixture.key, .abandoned)
        }
        #expect(inbox.queuedCount == fixtures.count * 3 + RuntimeClientInbox.trafficLimit)
        #expect(inbox.droppedTraffic == 10_000 - RuntimeClientInbox.trafficLimit)
        var sends = 0, replies = 0, ends = 0, events = 0
        while let message = inbox.take() {
            switch message {
            case .send: sends += 1
            case .reply: replies += 1
            case .ended: ends += 1
            case .incoming: events += 1
            default: Issue.record("Unexpected control message")
            }
        }
        #expect(sends == fixtures.count && replies == fixtures.count && ends == fixtures.count)
        #expect(events == RuntimeClientInbox.trafficLimit)
        #expect(inbox.reservationCount == 0)
        inbox.incoming(traffic)
        #expect(inbox.queuedCount == 1) // Draining actually restores traffic capacity.
    }

    @Test func totalQueueIncludesBoundedControlsAndOneFault() throws {
        let inbox = RuntimeClientInbox()
        for _ in 0..<RuntimeClientInbox.incomingLimit { inbox.incoming(.completed(Self.id)) }
        for _ in 0..<RuntimeClientInbox.interruptionLimit { inbox.interrupted(.init(cause: .connectionLost)) }
        let fixtures = try (0..<RuntimeClientInbox.requestLimit).map { _ in try reserve(inbox) }
        let duplicate = OperationID()
        for fixture in fixtures {
            inbox.replied(fixture.key, .success(.accepted(Self.id)))
            inbox.replied(fixture.key, .success(.accepted(duplicate)))
            inbox.ended(fixture.key, .abandoned)
            for _ in 0..<100 {
                inbox.replied(fixture.key, .success(.accepted(duplicate)))
                inbox.ended(fixture.key, .abandoned)
                inbox.incoming(.completed(Self.id))
                inbox.interrupted(.init(cause: .connectionLost))
            }
        }
        #expect(inbox.queuedCount == RuntimeClientInbox.queueLimit)
        #expect(inbox.terminalFailure == .malformedResponse)
        #expect(inbox.submit(fixtures[0].submission) == .faulted)
        var replies = 0, faults = 0
        while let message = inbox.take() {
            switch message {
            case .reply(_, .success(.accepted(let id))):
                #expect(id == Self.id || id == duplicate); replies += 1
            case .fault(let cause): #expect(cause == .malformedResponse); faults += 1
            default: break
            }
        }
        #expect(replies == fixtures.count * 2 && faults == 1)
        #expect(inbox.reservationCount == 0)
        #expect(inbox.submit(fixtures[0].submission) == .faulted) // Draining does not reopen a faulted inbox.
    }

    @Test func overflowAndAbandonmentKeepTheLateOwningIdentity() throws {
        let inbox = RuntimeClientInbox(), fixture = try reserve(inbox: nil)
        try #require(inbox.submit(fixture.submission) == .admitted)
        _ = inbox.take()
        inbox.ended(fixture.key, .abandoned)
        _ = inbox.take()
        #expect(inbox.reservationCount == 1)
        for _ in 0...RuntimeClientInbox.incomingLimit { inbox.incoming(.completed(Self.id)) }
        var faulted = false
        while let message = inbox.take() {
            if case .fault(let cause) = message { #expect(cause == .oversizedResponse); faulted = true }
        }
        #expect(faulted)
        inbox.replied(fixture.key, .success(.accepted(Self.id)))
        guard case .reply(let key, .success(.accepted(let id))) = inbox.take() else {
            Issue.record("Late owning acceptance was lost"); return
        }
        #expect(key === fixture.key && id == Self.id)
        #expect(inbox.reservationCount == 0)
    }

    @Test func interruptionsStayOrderedAndNeverCarryAnotherRequestsIdentity() {
        let inbox = RuntimeClientInbox()
        for _ in 0..<RuntimeClientInbox.interruptionLimit {
            inbox.interrupted(.init(cause: .protocolMismatch(service: 11), operationID: Self.id, mayHaveMutated: true))
        }
        inbox.interrupted(.init(cause: .connectionLost))
        for _ in 0..<RuntimeClientInbox.interruptionLimit {
            guard case .interrupted(let failure) = inbox.take() else { Issue.record("Lost interruption"); return }
            #expect(failure == RuntimeSessionFailure(cause: .protocolMismatch(service: 11)))
        }
        guard case .fault(.oversizedResponse) = inbox.take() else { Issue.record("Missing overflow fault"); return }
        #expect(inbox.take() == nil)
    }

    @Test func deadlineFaultStillReconcilesAnAcceptanceAfterObservedFailure() async throws {
        let inbox = RuntimeClientInbox(), fixture = InboxFixture(notifying: nil)
        try #require(inbox.submit(fixture.submission) == .admitted)
        guard case .send(let submission) = inbox.take() else { Issue.record("Missing send"); return }
        var router = RuntimeEventRouter()
        try #require(router.register(submission.key, request: submission.request, producer: submission.producer) == .admitted)
        inbox.fail(.connectionLost)
        guard case .fault(let cause) = inbox.take() else { Issue.record("Missing deadline fault"); return }
        let early = router.invalidate(cause)
        #expect(early.count == 2 && early.contains(.retireConnection))
        let failure = RuntimeSessionFailure(cause: .connectionLost, mayHaveMutated: true)
        var iterator = fixture.stream.makeAsyncIterator()
        await #expect(throws: failure) { try await iterator.next() }
        inbox.ended(fixture.key, .finished)
        _ = inbox.take()
        #expect(inbox.reservationCount == 1)
        inbox.replied(fixture.key, .success(.accepted(Self.id)))
        guard case .reply(let key, let result) = inbox.take() else { Issue.record("Missing late acceptance"); return }
        #expect(router.reply(result, to: key) == [.unknownOutcome(.init(key: key, environmentID: Self.environment,
            cancellationTarget: nil, failure: failure.contextualized(operationID: Self.id)))])
        #expect(router.isIdle && inbox.reservationCount == 0)
    }

    @Test func admissionAndKnownUnsentRejectionReleaseOnlySettledReservations() throws {
        let inbox = RuntimeClientInbox()
        let fixtures = try (0..<RuntimeClientInbox.requestLimit).map { _ in try reserve(inbox) }
        #expect(inbox.submit(fixtures[0].submission) == .full)
        inbox.rejectedBeforeSend(fixtures[0].key) // Still queued: cannot prematurely settle it.
        #expect(inbox.reservationCount == fixtures.count)
        for fixture in fixtures {
            guard case .send(let submission) = inbox.take() else { Issue.record("Lost send ordering"); return }
            #expect(submission.key === fixture.key)
            inbox.rejectedBeforeSend(fixture.key)
        }
        #expect(inbox.reservationCount == fixtures.count) // Consumers still own their end slots.
        for fixture in fixtures { inbox.ended(fixture.key, .finished) }
        while inbox.take() != nil {}
        #expect(inbox.reservationCount == 0)
        #expect(inbox.submit(fixtures[0].submission) == .admitted)
    }

    @Test func concurrentCallbacksReserveExactlyOnce() throws {
        let inbox = RuntimeClientInbox()
        let fixtures = try (0..<RuntimeClientInbox.requestLimit).map { _ in try reserve(inbox) }
        DispatchQueue.concurrentPerform(iterations: fixtures.count) { index in
            let fixture = fixtures[index]
            inbox.replied(fixture.key, .success(.accepted(Self.id)))
            inbox.ended(fixture.key, .abandoned)
        }
        #expect(inbox.queuedCount == fixtures.count * 3)
        while inbox.take() != nil {}
        #expect(inbox.reservationCount == 0)
    }

    @Test func wakeupStorageIsOnePayloadFreeSignalAndFinishesOnRelease() async throws {
        var inbox: RuntimeClientInbox? = RuntimeClientInbox()
        let wakeups = try #require(inbox).wakeups
        for _ in 0..<10_000 { inbox?.incoming(Self.traffic[0]) }
        weak let weakInbox = inbox
        inbox = nil
        #expect(weakInbox == nil)
        var count = 0
        for await _ in wakeups { count += 1 }
        #expect(count == 1)
    }

    @Test func concurrentEnqueueAndDrainDoNotLoseWakeupsOrReservations() async throws {
        let inbox = RuntimeClientInbox()
        let fixtures = try (0..<RuntimeClientInbox.requestLimit).map { _ in try reserve(inbox) }
        let reader = Task {
            var count = 0
            for await _ in inbox.wakeups {
                while inbox.take() != nil {
                    count += 1
                    if count == RuntimeClientInbox.requestLimit * 3 { return count }
                }
            }
            return count
        }
        defer { reader.cancel() }
        DispatchQueue.concurrentPerform(iterations: fixtures.count) { index in
            inbox.replied(fixtures[index].key, .success(.accepted(Self.id)))
            inbox.ended(fixtures[index].key, .finished)
        }
        #expect(await reader.value == fixtures.count * 3)
        #expect(inbox.reservationCount == 0 && inbox.queuedCount == 0)
    }

    @Test(arguments: [false, true])
    func realTransportRegistryFeedsTheRouterInCallbackOrder(terminalBeforeDrop: Bool) async throws {
        let inbox = RuntimeClientInbox()
        let fixture = InboxFixture(notifying: inbox)
        let client = XPCRuntimeTransport(incoming: { inbox.incoming($0) }, interrupted: { inbox.interrupted($0) }, connect: { incoming, dropped in
            InboxSession(id: Self.id, terminal: terminalBeforeDrop, incoming: incoming, dropped: dropped)
        })
        try #require(inbox.submit(fixture.submission) == .admitted)
        var router = RuntimeEventRouter(), effects: [RuntimeEventRouter.Effect] = []
        while let message = inbox.take() {
            switch message {
            case .send(let submission):
                try #require(router.register(submission.key, request: submission.request, producer: submission.producer) == .admitted)
                try client.send(.init(request: submission.request)) { inbox.replied(submission.key, $0) }
            case .reply(let key, let result): effects += router.reply(result, to: key)
            case .incoming(let event): effects += router.incoming(event)
            case .interrupted(let failure): effects += router.interrupted(failure)
            case .ended(let key, let reason): effects += router.consumerEnded(key, reason: reason)
            case .fault: Issue.record("Unexpected fault")
            }
        }
        var iterator = fixture.stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted(Self.id))
        if terminalBeforeDrop {
            #expect(try await iterator.next() == .completed(Self.id))
            #expect(try await iterator.next() == nil)
            #expect(effects.isEmpty)
        } else {
            let failure = RuntimeSessionFailure(cause: .connectionLost, operationID: Self.id, mayHaveMutated: true)
            await #expect(throws: failure) { try await iterator.next() }
            #expect(effects == [.unknownOutcome(.init(key: fixture.key, environmentID: Self.environment, cancellationTarget: nil, failure: failure))])
        }
        #expect(router.isIdle)
        #expect(inbox.reservationCount == 0)
        withExtendedLifetime(client) {}
    }
}

private struct InboxFixture: Sendable {
    let key = RuntimeRequestKey()
    let producer: RuntimeEventStream
    let stream: AsyncThrowingStream<RuntimeEvent, any Error>
    var submission: RuntimeClientInbox.Submission {
        .init(key: key, request: .startEnvironment(RuntimeClientInboxTests.environment, .init()), producer: producer)
    }
    init(notifying inbox: RuntimeClientInbox? = nil) {
        let key = self.key
        (producer, stream) = RuntimeEventStream.make(mayHaveMutated: true) { inbox?.ended(key, $0) }
    }
}
private func reserve(_ inbox: RuntimeClientInbox) throws -> InboxFixture { try reserve(inbox: inbox) }
private func reserve(inbox: RuntimeClientInbox?) throws -> InboxFixture {
    let fixture = InboxFixture()
    if let inbox { try #require(inbox.submit(fixture.submission) == .admitted) }
    return fixture
}
private final class InboxSession: RuntimeClientSession {
    let id: OperationID, terminal: Bool
    let incoming: @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void
    let dropped: @Sendable () -> Void
    init(id: OperationID, terminal: Bool, incoming: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void,
         dropped: @escaping @Sendable () -> Void) {
        self.id = id; self.terminal = terminal; self.incoming = incoming; self.dropped = dropped
    }
    func activate() {}
    func cancel() { dropped() } // Synchronous reentry exercises registry cleanup outside its delivery lock.
    func send(_ payload: Data, reply: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void) {
        reply(.success(.accepted(id)))
        if terminal { incoming(.success(.completed(id))) }
        dropped()
    }
}
