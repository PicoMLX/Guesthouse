import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseClientKit

@Suite(.timeLimit(.minutes(1))) struct RuntimeClientTests {
    static let info = RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1")
    static let environment = EnvironmentID(), id = OperationID()
    static let start = RuntimeRequest.startEnvironment(environment, .init())

    @Test func publicBackendRefusesMutationsWithoutConnecting() async {
        let client: any RuntimeBackend = RuntimeClient()
        var iterator = client.send(Self.start).makeAsyncIterator()
        await #expect(throws: GuesthouseError.invalidRequest(.unsupportedOperation)) { try await iterator.next() }
    }

    @Test func orderedRequestsAndPushesUseTheActualOwner() async throws {
        let fixture = OwnerFixture(), client = fixture.client()
        let first = client.send(Self.start), second = client.send(.runtimeVersion)
        await client.flush()
        let peer = try #require(fixture.latest)
        #expect(peer.requests == [Self.start, .runtimeVersion])
        peer.incoming(.success(.completed(Self.id))) // Terminal before owning acceptance.
        peer.answer(1, .success(.runtimeVersion(Self.info)))
        peer.answer(0, .success(.accepted(Self.id)))
        var operation = first.makeAsyncIterator(), query = second.makeAsyncIterator()
        #expect(try await query.next() == .runtimeVersion(Self.info))
        #expect(try await query.next() == nil)
        #expect(try await operation.next() == .accepted(Self.id))
        #expect(try await operation.next() == .completed(Self.id))
        #expect(try await operation.next() == nil)
        await client.flush()
        #expect(await client.reconciliation().0.isEmpty)
    }

    @Test func publicQueryPolicyAllowsPreflightButDoesNotOpenTheOperationAPI() async throws {
        let fixture = OwnerFixture(), client = fixture.client(permitsOperations: false)
        var query = client.send(.hostPreflight).makeAsyncIterator()
        await client.flush()
        let peer = try #require(fixture.latest)
        #expect(peer.requests == [.hostPreflight])
        let report = PreflightCheck.run(snapshot: HostProbeSnapshot())
        peer.answer(0, .success(.hostPreflight(report)))
        #expect(try await query.next() == .hostPreflight(report))
        #expect(try await query.next() == nil)
        var mutation = client.send(Self.start).makeAsyncIterator()
        await #expect(throws: GuesthouseError.invalidRequest(.unsupportedOperation)) { try await mutation.next() }
        #expect(peer.requests == [.hostPreflight])
        #expect(await client.reconciliation().0.isEmpty)
        await client.close()
        #expect(peer.cancelCount == 1)
    }

    @Test func preflightTransportFailureDoesNotInventAnUnknownMutationOrReplay() async throws {
        let fixture = OwnerFixture(), client = fixture.client(permitsOperations: false)
        var query = client.send(.hostPreflight).makeAsyncIterator()
        await client.flush()
        let peer = try #require(fixture.latest)
        peer.answer(0, .failure(.init(cause: .connectionLost)))
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost)) { try await query.next() }
        await client.flush()
        #expect(await client.reconciliation().0.isEmpty)
        #expect(await client.reconciliation().1.isEmpty)
        #expect(peer.requests == [.hostPreflight])
        #expect(fixture.connectionCount == 1)
        await client.close()
    }

    @Test(arguments: [false, true])
    func abandoningAnOperationSendsOneTrackedCancellation(beforeReply: Bool) async throws {
        let fixture = OwnerFixture(), client = fixture.client()
        var stream: AsyncThrowingStream<RuntimeEvent, any Error>? = client.send(Self.start)
        await client.flush()
        let peer = try #require(fixture.latest)
        if !beforeReply { peer.answer(0, .success(.accepted(Self.id))); await client.flush() }
        withExtendedLifetime(stream) {}; stream = nil
        await client.flush()
        if beforeReply { peer.answer(0, .success(.accepted(Self.id))); await client.flush() }
        #expect(peer.requests == [Self.start, .cancelOperation(Self.id)])
        peer.answer(1, .success(.completed(OperationID()))) // Acknowledgment is not target completion.
        await client.flush()
        #expect(await client.reconciliation().1 == [Self.id])
        var next = client.send(Self.start).makeAsyncIterator()
        await #expect(throws: GuesthouseError.runtimeIncompatible) { try await next.next() }
        #expect(peer.requests.count == 2)
    }

    @Test func deadlineFailureStillLearnsLateAcceptanceAndNeverReplays() async throws {
        let fixture = OwnerFixture(), client = fixture.client(deadline: {})
        var iterator = client.send(Self.start).makeAsyncIterator()
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost, mayHaveMutated: true)) { try await iterator.next() }
        await client.flush()
        let peer = try #require(fixture.latest)
        #expect(peer.cancelCount == 1 && peer.requests.count == 1)
        peer.answer(0, .success(.accepted(Self.id)))
        await client.flush()
        let pending = await client.reconciliation().0
        #expect(pending.count == 1 && pending.first?.environmentID == Self.environment)
        #expect(pending.first?.failure.operationID == Self.id && pending.first?.failure.mayHaveMutated == true)
        var refused = client.send(Self.start).makeAsyncIterator()
        await #expect(throws: GuesthouseError.runtimeIncompatible) { try await refused.next() }
        #expect(fixture.connectionCount == 1 && peer.requests.count == 1)
    }

    @Test func owningReplyAlreadyQueuedBeatsItsDeadline() throws {
        let inbox = RuntimeClientInbox(), key = RuntimeRequestKey()
        let (producer, stream) = RuntimeEventStream.make(mayHaveMutated: false) { _ in }
        try #require(inbox.submit(.init(key: key, request: .runtimeVersion, producer: producer)) == .admitted)
        _ = inbox.take()
        let reply = try #require(inbox.replyHandler(for: key))
        reply(.success(.runtimeVersion(Self.info)))
        inbox.expireReply(key)
        #expect(inbox.terminalFailure == nil)
        withExtendedLifetime((stream, reply)) {}
    }

    @Test func aDroppedReadOnlyConnectionReconnectsOnlyForANewRequest() async throws {
        let fixture = OwnerFixture(), client = fixture.client()
        var first = client.send(.runtimeVersion).makeAsyncIterator()
        await client.flush()
        let peer = try #require(fixture.latest)
        peer.answer(0, .failure(.init(cause: .connectionLost)))
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost)) { try await first.next() }
        await client.flush()
        #expect(fixture.connectionCount == 1)
        var second = client.send(.runtimeVersion).makeAsyncIterator()
        await client.flush()
        #expect(fixture.connectionCount == 2)
        fixture.latest?.answer(0, .success(.runtimeVersion(Self.info)))
        #expect(try await second.next() == .runtimeVersion(Self.info))
        #expect(peer.requests.count == 1)
    }

    @Test func opaqueSetupFailureIsKnownUnsentAndReleasesItsReservation() async throws {
        let calls = Mutex(0)
        let failures = RuntimeEventRouter.lifetimeLimit + 1
        let peer = OwnerPeer(incoming: { _ in }, dropped: {})
        let client = RuntimeClient(connect: { _, _ in
            if calls.withLock({ $0 += 1; return $0 }) <= failures {
                throw NSError(domain: "private-marker", code: 1)
            }
            return peer
        })
        for _ in 0..<failures {
            var iterator = client.send(Self.start).makeAsyncIterator()
            await #expect(throws: GuesthouseError.runtimeIncompatible) { try await iterator.next() }
            await client.flush()
        }
        var recovered = client.send(.runtimeVersion).makeAsyncIterator()
        await client.flush()
        peer.answer(0, .success(.runtimeVersion(Self.info)))
        #expect(try await recovered.next() == .runtimeVersion(Self.info))
        #expect(calls.withLock { $0 } == failures + 1)
        #expect(peer.requests == [.runtimeVersion])
        #expect(await client.reconciliation().0.isEmpty)
    }

    @Test func capacityRefusalDoesNotSendOrLeakAnotherPendingRequest() async throws {
        let fixture = OwnerFixture(), client = fixture.client()
        let streams = (0..<64).map { _ in client.send(.runtimeVersion) }
        await client.flush()
        var refused = client.send(.runtimeVersion).makeAsyncIterator()
        await #expect(throws: GuesthouseError.invalidRequest(.tooManyInFlight)) { try await refused.next() }
        let peer = try #require(fixture.latest)
        #expect(peer.requests.count == 64)
        for index in 0..<64 { peer.answer(index, .success(.runtimeVersion(Self.info))) }
        await client.flush()
        var next = client.send(.runtimeVersion).makeAsyncIterator()
        await client.flush()
        peer.answer(64, .success(.runtimeVersion(Self.info)))
        #expect(try await next.next() == .runtimeVersion(Self.info))
        withExtendedLifetime(streams) {}
    }

    @Test func streamKeepsClientAliveUntilCompletionThenReleasesNativeState() async throws {
        let fixture = OwnerFixture()
        var client: RuntimeClient? = fixture.client()
        weak let weakClient = client
        let stream = try #require(client).send(.runtimeVersion)
        await client?.flush()
        client = nil
        #expect(weakClient != nil)
        let peer = try #require(fixture.latest)
        peer.answer(0, .success(.runtimeVersion(Self.info)))
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .runtimeVersion(Self.info))
        #expect(try await iterator.next() == nil)
        for await _ in peer.canceled { break } // Await isolated native cleanup, not a sleep.
        #expect(weakClient == nil && peer.cancelCount == 1)
    }

    @Test func completedConsumerDoesNotLoseADistinctDuplicateAcceptance() async throws {
        let fixture = OwnerFixture(), client = fixture.client(), other = OperationID()
        var iterator = client.send(Self.start).makeAsyncIterator()
        await client.flush()
        let peer = try #require(fixture.latest)
        peer.answer(0, .success(.accepted(Self.id)), retaining: true)
        peer.incoming(.success(.completed(Self.id)))
        #expect(try await iterator.next() == .accepted(Self.id))
        #expect(try await iterator.next() == .completed(Self.id))
        #expect(try await iterator.next() == nil)
        await client.flush()
        peer.answer(0, .success(.accepted(other)))
        await client.flush()
        let unknown = await client.reconciliation().0
        #expect(unknown.count == 1 && unknown.first?.failure.operationID == other)
        #expect(unknown.first?.environmentID == Self.environment && peer.cancelCount == 1)
        #expect(try await iterator.next() == nil)
    }

    @Test(arguments: [false, true])
    func finiteClientLifetimeRefusesAdditionalNativeWork(lastOperation: Bool) async throws {
        let fixture = OwnerFixture(), client = fixture.client()
        for index in 0..<(RuntimeEventRouter.lifetimeLimit - 1) {
            var iterator = client.send(.runtimeVersion).makeAsyncIterator()
            await client.flush()
            fixture.latest?.answer(index, .success(.runtimeVersion(Self.info)))
            #expect(try await iterator.next() == .runtimeVersion(Self.info))
            await client.flush()
        }
        var last: AsyncThrowingStream<RuntimeEvent, any Error>? = client.send(lastOperation ? Self.start : .runtimeVersion)
        await client.flush()
        fixture.latest?.answer(RuntimeEventRouter.lifetimeLimit - 1,
                              .success(lastOperation ? .accepted(Self.id) : .runtimeVersion(Self.info)))
        await client.flush()
        withExtendedLifetime(last) {}; last = nil
        await client.flush()
        if lastOperation {
            #expect(await client.reconciliation().1 == [Self.id])
            #expect(fixture.latest?.cancelCount == 1) // Cancellation refusal must retire too.
        }
        var refused = client.send(.runtimeVersion).makeAsyncIterator()
        await #expect(throws: GuesthouseError.runtimeIncompatible) { try await refused.next() }
        #expect(fixture.latest?.requests.count == RuntimeEventRouter.lifetimeLimit)
    }
}

private final class OwnerFixture: Sendable {
    private let peers = Mutex<[OwnerPeer]>([])
    var latest: OwnerPeer? { peers.withLock { $0.last } }
    var connectionCount: Int { peers.withLock { $0.count } }
    func client(permitsOperations: Bool = true,
                deadline: @escaping RuntimeClient.Deadline = { try await Task.sleep(for: .seconds(10)) }) -> RuntimeClient {
        RuntimeClient(connect: { [self] incoming, dropped in
            let peer = OwnerPeer(incoming: incoming, dropped: dropped)
            peers.withLock { $0.append(peer) }; return peer
        }, permitsOperations: permitsOperations, deadline: deadline)
    }
}
private final class OwnerPeer: RuntimeClientSession {
    struct State { var requests: [RuntimeRequest] = []; var replies: [RuntimeClientInbox.Reply?] = []; var cancels = 0 }
    private let state = Mutex(State())
    let incoming: @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void
    let dropped: @Sendable () -> Void
    let canceled: AsyncStream<Void>
    let signal: AsyncStream<Void>.Continuation
    var requests: [RuntimeRequest] { state.withLock { $0.requests } }
    var cancelCount: Int { state.withLock { $0.cancels } }
    init(incoming: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void,
         dropped: @escaping @Sendable () -> Void) {
        self.incoming = incoming; self.dropped = dropped
        (canceled, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    func activate() {}
    func cancel() { state.withLock { $0.cancels += 1 }; dropped(); signal.yield(()); signal.finish() }
    func send(_ data: Data, reply: @escaping RuntimeClientInbox.Reply) {
        do {
            let request = try JSONDecoder().decode(RuntimeRequestEnvelope.self, from: data).request
            state.withLock { $0.requests.append(request); $0.replies.append(reply) }
        } catch { Issue.record("Invalid test request"); reply(.failure(.init(cause: .malformedResponse))) }
    }
    func answer(_ index: Int, _ result: Result<RuntimeEvent, RuntimeSessionFailure>, retaining: Bool = false) {
        let reply = state.withLock { state in
            guard state.replies.indices.contains(index) else { Issue.record("Missing test reply"); return RuntimeClientInbox.Reply?.none }
            let reply = state.replies[index]; if !retaining { state.replies[index] = nil }; return reply
        }
        reply?(result) // Invocations and last callback releases stay outside fixture locks.
    }
}
