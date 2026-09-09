import Dispatch
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseClientKit

@Suite(.timeLimit(.minutes(1))) struct RuntimeClientInboxTests {
    static let id = OperationID(), otherID = OperationID(), environment = EnvironmentID()
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
            fixture.answer(.success(.accepted(Self.id)))
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
        #expect(inbox.reservationCount == fixtures.count) // Callback captures still own the duplicate window.
        #expect(inbox.submit(InboxFixture().submission) == .full)
        for fixture in fixtures { fixture.releaseReply() }
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
            fixture.answer(.success(.accepted(Self.id)))
            fixture.answer(.success(.accepted(duplicate)))
            inbox.ended(fixture.key, .abandoned)
            for _ in 0..<100 {
                fixture.answer(.success(.accepted(duplicate)))
                inbox.ended(fixture.key, .abandoned)
                inbox.incoming(.completed(Self.id))
                inbox.interrupted(.init(cause: .connectionLost))
            }
            fixture.releaseReply()
        }
        #expect(inbox.queuedCount == RuntimeClientInbox.queueLimit)
        #expect(inbox.terminalFailure == .malformedResponse)
        #expect(inbox.submit(fixtures[0].submission) == .faulted)
        var replies = 0, faults = 0
        while let message = inbox.take() {
            switch message {
            case .reply(_, .success(.accepted(let id))):
                #expect(id == Self.id); replies += 1
            case .unexpectedReply(let context): #expect(context.failure.operationID == duplicate); replies += 1
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
        try fixture.prepareReply(inbox)
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
        fixture.answer(.success(.accepted(Self.id)))
        fixture.releaseReply()
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
        try fixture.prepareReply(inbox)
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
        fixture.answer(.success(.accepted(Self.id)))
        fixture.releaseReply()
        guard case .reply(let key, let result) = inbox.take() else { Issue.record("Missing late acceptance"); return }
        #expect(router.reply(result, to: key) == [.unknownOutcome(.init(key: key, environmentID: Self.environment,
            cancellationTarget: nil, failure: failure.contextualized(operationID: Self.id)))])
        #expect(router.isIdle && inbox.reservationCount == 0)
    }

    @Test(arguments: [false, true])
    func admissionAndKnownUnsentRejectionReleaseOnlySettledReservations(withHandler: Bool) throws {
        let inbox = RuntimeClientInbox()
        let fixtures = try (0..<RuntimeClientInbox.requestLimit).map { _ in try reserve(inbox: inbox, handler: withHandler) }
        #expect(inbox.submit(fixtures[0].submission) == .full)
        inbox.rejectedBeforeSend(fixtures[0].key) // Still queued: cannot prematurely settle it.
        #expect(inbox.reservationCount == fixtures.count)
        for fixture in fixtures {
            guard case .send(let submission) = inbox.take() else { Issue.record("Lost send ordering"); return }
            #expect(submission.key === fixture.key)
            inbox.rejectedBeforeSend(fixture.key)
            fixture.releaseReply()
        }
        #expect(inbox.reservationCount == fixtures.count) // Consumers still own their end slots.
        for fixture in fixtures { inbox.ended(fixture.key, .finished) }
        while inbox.take() != nil {}
        #expect(inbox.reservationCount == 0)
        #expect(inbox.submit(fixtures[0].submission) == .admitted)
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

    @Test(arguments: traffic, [false, true])
    func discardedCallbacksDoNotLeaveAnotherWakeup(traffic: RuntimeEvent, faulted: Bool) async throws {
        var inbox: RuntimeClientInbox? = RuntimeClientInbox()
        for _ in 0..<RuntimeClientInbox.trafficLimit { inbox?.incoming(traffic) }
        if faulted { inbox?.fail(.connectionLost) }
        var iterator = try #require(inbox).wakeups.makeAsyncIterator()
        try #require(await iterator.next() != nil) // Consume the admitted work's coalesced signal.
        let unknown = RuntimeRequestKey()
        for _ in 0..<10_000 {
            inbox?.incoming(traffic)
            inbox?.ended(unknown, .finished)
            if faulted {
                inbox?.incoming(.completed(Self.id))
                inbox?.interrupted(.init(cause: .connectionLost))
                inbox?.fail(.connectionLost)
            }
        }
        #expect(inbox?.queuedCount == RuntimeClientInbox.trafficLimit + (faulted ? 1 : 0))
        inbox = nil // Finish deterministically; no sleep or timeout to prove absence of signals.
        #expect(await iterator.next() == nil)
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
            fixtures[index].answer(.success(.accepted(Self.id)))
            inbox.ended(fixtures[index].key, .finished)
            fixtures[index].releaseReply()
        }
        #expect(await reader.value == fixtures.count * 3)
        #expect(inbox.reservationCount == 0 && inbox.queuedCount == 0)
    }

    @Test func completedConsumerStillRetainsTheDuplicateAcceptanceIdentity() async throws {
        let inbox = RuntimeClientInbox(), secondID = OperationID()
        let fixture = InboxFixture(notifying: inbox)
        try #require(inbox.submit(fixture.submission) == .admitted)
        try fixture.prepareReply(inbox)
        _ = inbox.take() // Send; the owner has registered it with the router.
        fixture.answer(.success(.accepted(Self.id)))
        _ = inbox.take()
        fixture.producer.reply(.accepted(Self.id)); fixture.producer.push(.completed(Self.id))
        _ = inbox.take() // Automatic consumer-end notice; normal routing has finished.
        var iterator = fixture.stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted(Self.id))
        #expect(try await iterator.next() == .completed(Self.id))
        #expect(try await iterator.next() == nil)
        #expect(inbox.reservationCount == 1)
        fixture.answer(.success(.accepted(secondID)))
        guard case .unexpectedReply(let context) = inbox.take() else { Issue.record("Lost second identity"); return }
        #expect(context == .init(key: fixture.key, environmentID: Self.environment, cancellationTarget: nil,
            failure: .init(cause: .malformedResponse, operationID: secondID, mayHaveMutated: true)))
        guard case .fault(.malformedResponse) = inbox.take() else { Issue.record("Missing duplicate fault"); return }
        #expect(try await iterator.next() == nil) // Do not rewrite the completed consumer.
        fixture.releaseReply()
        #expect(inbox.reservationCount == 0)
    }

    static let duplicateReplies: [(Result<RuntimeEvent, RuntimeSessionFailure>, Bool)] = [
        (.success(.accepted(id)), false), (.success(.accepted(otherID)), true),
        (.success(.completed(otherID)), false), (.success(.progress(otherID, .init(kind: .copying))), false),
        (.success(.failed(otherID, .invalidRequest(.malformed))), false),
        (.success(.diagnostic(.init(operation: .startEnvironment, outcome: .started, operationID: otherID.uuid))), false),
        (.success(.status(.init(environmentID: environment, vm: .running, readiness: .checking, inFlightOperation: otherID))), false),
        (.failure(.init(cause: .connectionLost, mayHaveMutated: true)), false),
        (.failure(.init(cause: .connectionLost, operationID: id, mayHaveMutated: true)), false),
        (.failure(.init(cause: .connectionLost, operationID: otherID, mayHaveMutated: true)), true),
    ]

    @Test(arguments: duplicateReplies, [false, true])
    func duplicateReconciliationRequiresAnAdditionalUncertainID(
        duplicate: (Result<RuntimeEvent, RuntimeSessionFailure>, Bool), firstFailed: Bool
    ) throws {
        let inbox = RuntimeClientInbox(), fixture = try reserve(inbox)
        _ = inbox.take()
        fixture.answer(firstFailed ? .failure(.init(cause: .connectionLost, operationID: Self.id, mayHaveMutated: true))
                                   : .success(.accepted(Self.id)))
        _ = inbox.take(); inbox.ended(fixture.key, .finished); _ = inbox.take()
        fixture.answer(duplicate.0)
        if duplicate.1 {
            guard case .unexpectedReply(let context) = inbox.take() else { Issue.record("Missing additional identity"); return }
            #expect(context.failure.operationID == Self.otherID && context.key === fixture.key)
        }
        guard case .fault(.malformedResponse) = inbox.take() else { Issue.record("Missing duplicate fault"); return }
        #expect(inbox.take() == nil) // No uncertainty for repeated IDs or non-acceptance events.
        fixture.releaseReply()
        #expect(inbox.reservationCount == 0)
    }

    @Test func discardedUnansweredHandlerSettlesItsOwningReplyAndRequiresRetirement() async throws {
        let inbox = RuntimeClientInbox(), fixture = try reserve(inbox: nil)
        try #require(inbox.submit(fixture.submission) == .admitted)
        try fixture.prepareReply(inbox)
        #expect(inbox.replyHandler(for: fixture.key) == nil)
        guard case .send(let submission) = inbox.take() else { Issue.record("Missing send"); return }
        var router = RuntimeEventRouter()
        try #require(router.register(submission.key, request: submission.request, producer: submission.producer) == .admitted)
        fixture.releaseReply() // No closure remains that could provide a later response.
        #expect(inbox.terminalFailure == .connectionLost && inbox.submit(InboxFixture().submission) == .faulted)
        guard case .reply(let key, .failure(let failure)) = inbox.take() else { Issue.record("Missing failure"); return }
        #expect(key === fixture.key && failure == RuntimeSessionFailure(cause: .connectionLost))
        #expect(router.reply(.failure(failure), to: key) == [.unknownOutcome(.init(key: key, environmentID: Self.environment,
            cancellationTarget: nil, failure: failure.contextualized(mayHaveMutated: true)))])
        guard case .fault(let cause) = inbox.take() else { Issue.record("Missing retirement fault"); return }
        #expect(router.invalidate(cause) == [.retireConnection])
        var iterator = fixture.stream.makeAsyncIterator()
        await #expect(throws: failure.contextualized(mayHaveMutated: true)) { try await iterator.next() }
        inbox.ended(key, .finished); _ = inbox.take()
        #expect(inbox.reservationCount == 0)
        #expect(inbox.submit(InboxFixture().submission) == .faulted)
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
                try client.send(.init(request: submission.request), reply: #require(inbox.replyHandler(for: submission.key)))
            case .reply(let key, let result): effects += router.reply(result, to: key)
            case .incoming(let event): effects += router.incoming(event)
            case .interrupted(let failure): effects += router.interrupted(failure)
            case .ended(let key, let reason): effects += router.consumerEnded(key, reason: reason)
            case .unexpectedReply: Issue.record("Unexpected duplicate reply")
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

    @Test func retiredDuplicateAcceptanceKeepsItsTransportFailureIdentity() throws {
        let inbox = RuntimeClientInbox(), fixture = InboxFixture()
        let client = XPCRuntimeTransport(incoming: { inbox.incoming($0) }, interrupted: { inbox.interrupted($0) }, connect: { incoming, dropped in
            InboxSession(id: Self.id, terminal: false, duplicateAfterDrop: Self.otherID, incoming: incoming, dropped: dropped)
        })
        try #require(inbox.submit(fixture.submission) == .admitted)
        _ = inbox.take()
        try client.send(.init(request: fixture.submission.request), reply: #require(inbox.replyHandler(for: fixture.key)))
        guard case .reply(_, .success(.accepted(Self.id))) = inbox.take() else { Issue.record("Missing first reply"); return }
        guard case .interrupted = inbox.take() else { Issue.record("Missing retirement"); return }
        // The real registry converted the second acceptance to a request-specific failure.
        guard case .unexpectedReply(let context) = inbox.take() else { Issue.record("Lost retired acceptance ID"); return }
        #expect(context == .init(key: fixture.key, environmentID: Self.environment, cancellationTarget: nil,
            failure: .init(cause: .malformedResponse, operationID: Self.otherID, mayHaveMutated: true)))
        guard case .fault(.malformedResponse) = inbox.take() else { Issue.record("Missing duplicate fault"); return }
        inbox.ended(fixture.key, .finished); _ = inbox.take()
        #expect(inbox.reservationCount == 0 && inbox.take() == nil)
        withExtendedLifetime(client) {}
    }
}

private final class InboxFixture: Sendable {
    let key: RuntimeRequestKey
    let producer: RuntimeEventStream
    let stream: AsyncThrowingStream<RuntimeEvent, any Error>
    private let reply = Mutex<RuntimeClientInbox.Reply?>(nil)
    var submission: RuntimeClientInbox.Submission {
        .init(key: key, request: .startEnvironment(RuntimeClientInboxTests.environment, .init()), producer: producer)
    }
    init(notifying inbox: RuntimeClientInbox? = nil) {
        let key = RuntimeRequestKey(); self.key = key
        (producer, stream) = RuntimeEventStream.make(mayHaveMutated: true) { inbox?.ended(key, $0) }
    }
    func prepareReply(_ inbox: RuntimeClientInbox) throws {
        let handler = try #require(inbox.replyHandler(for: key))
        reply.withLock { $0 = handler }
    }
    func answer(_ result: Result<RuntimeEvent, RuntimeSessionFailure>) { reply.withLock { $0 }?(result) }
    func releaseReply() {
        let old = reply.withLock { value in let old = value; value = nil; return old }
        withExtendedLifetime(old) {} // Release the callback outside the fixture lock too.
    }
}
private func reserve(_ inbox: RuntimeClientInbox) throws -> InboxFixture { try reserve(inbox: inbox) }
private func reserve(inbox: RuntimeClientInbox?, handler: Bool = true) throws -> InboxFixture {
    let fixture = InboxFixture()
    if let inbox {
        try #require(inbox.submit(fixture.submission) == .admitted)
        if handler { try fixture.prepareReply(inbox) }
    }
    return fixture
}
private final class InboxSession: RuntimeClientSession {
    let id: OperationID, terminal: Bool
    let duplicateAfterDrop: OperationID?
    let incoming: @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void
    let dropped: @Sendable () -> Void
    init(id: OperationID, terminal: Bool, duplicateAfterDrop: OperationID? = nil,
         incoming: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void,
         dropped: @escaping @Sendable () -> Void) {
        self.id = id; self.terminal = terminal; self.incoming = incoming; self.dropped = dropped
        self.duplicateAfterDrop = duplicateAfterDrop
    }
    func activate() {}
    func cancel() { dropped() } // Synchronous reentry exercises registry cleanup outside its delivery lock.
    func send(_ payload: Data, reply: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void) {
        reply(.success(.accepted(id)))
        if terminal { incoming(.success(.completed(id))) }
        dropped()
        if let duplicateAfterDrop { reply(.success(.accepted(duplicateAfterDrop))) }
    }
}
