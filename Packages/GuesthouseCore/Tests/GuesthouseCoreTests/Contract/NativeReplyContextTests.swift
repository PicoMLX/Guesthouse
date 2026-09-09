import Dispatch
import Foundation
import Synchronization
import Testing
import XPC
@testable import GuesthouseCore

private let fixtureVersion = Int64(RuntimeProtocolVersion.current.rawValue)

/// Actual anonymous transport, not signed-caller proof or production endpoint activation.
/// Authentication is outside this primitive; no fixture decision authorizes a real caller.
@Suite(.timeLimit(.minutes(1))) struct NativeReplyContextTests {
    @Test func unreceivedDictionaryHasNoReplyContext() {
        #expect(RawRuntimeReplyContext(receivedMessage: XPCDictionary()) == nil)
    }

    @Test func retainedRepliesCanBeSentInReverseOrderAndRemainCorrelated() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let first = fixture.request()
        let firstIncoming = try await next(fixture.incoming)
        let second = fixture.request()
        let secondIncoming = try await next(fixture.incoming)
        let firstContext = try #require(firstIncoming.context)
        let secondContext = try #require(secondIncoming.context)
        #expect(firstIncoming.secondCreationRejected)
        #expect(secondIncoming.secondCreationRejected)
        // Receiving the second message lets the first handler return without an implicit
        // reply. Neither the test nor the context retains the original received dictionary.
        try fixture.send(secondContext, bytes: Data([2]))
        try fixture.send(firstContext, bytes: Data([1]))
        #expect(try await next(first) == Data([1]))
        #expect(try await next(second) == Data([2]))
        #expect(try firstContext.takeReply(payload: Data([3]), protocolVersion: fixtureVersion) == nil)
        #expect(try secondContext.takeReply(payload: Data([3]), protocolVersion: fixtureVersion) == nil)
    }

    @Test func oneWayMessageDoesNotConsumeTheNextRequestsReplyContext() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        try fixture.client.send(message: XPCDictionary())
        let oneWay = try await next(fixture.incoming)
        #expect(oneWay.context == nil)
        #expect(oneWay.secondCreationRejected)
        let reply = fixture.request()
        let context = try #require(try await next(fixture.incoming).context)
        try fixture.send(context, bytes: Data([7]))
        #expect(try await next(reply) == Data([7]))
    }

    @Test(arguments: [0, RawRuntimeFrame.maximumPayloadBytes + 1])
    func invalidEncodingPreservesTheContextForATypedFailure(_ count: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let reply = fixture.request()
        let context = try #require(try await next(fixture.incoming).context)
        let expected: RawRuntimeFrame.Failure = count == 0 ? .malformed : .oversized
        #expect(throws: expected) {
            try context.takeReply(payload: Data(repeating: 0, count: count), protocolVersion: fixtureVersion)
        }
        let failure = try RuntimeEventEnvelope(event: .failed(OperationID(), .invalidRuntimeReply(.malformed))).encoded()
        try fixture.send(context, bytes: failure)
        let data = try await next(reply)
        let decoded = try RuntimeEventEnvelope.decode(data)
        guard case .failed(_, .invalidRuntimeReply(.malformed)) = decoded.event else {
            Issue.record("Expected the fixed typed encoding-failure response")
            return
        }
    }

    @Test func exactPayloadBoundarySurvivesExplicitReplyHandoff() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let reply = fixture.request()
        let context = try #require(try await next(fixture.incoming).context)
        let bytes = Data(repeating: 32, count: RawRuntimeFrame.maximumPayloadBytes)
        try fixture.send(context, bytes: bytes)
        #expect(try await next(reply) == bytes)
    }

    @Test func aClaimedReplyCannotBeReclaimedWithoutSuccessfulDelivery() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        _ = fixture.request()
        let context = try #require(try await next(fixture.incoming).context)
        // Deliberately discard the claimed frame without sending it. A caller whose send
        // failed or whose session disappeared likewise cannot acquire a second context.
        let claimed = try context.takeReply(payload: Data([6]), protocolVersion: fixtureVersion)
        #expect(claimed != nil)
        #expect(try context.takeReply(payload: Data([6]), protocolVersion: fixtureVersion) == nil)
    }

    @Test func concurrentClaimsHaveExactlyOneReplyOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let reply = fixture.request()
        let context = try #require(try await next(fixture.incoming).context)
        let claims = Mutex(0)
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                if let message = try context.takeReply(payload: Data([9]), protocolVersion: fixtureVersion) {
                    claims.withLock { $0 += 1 }
                    try fixture.server().send(message: message)
                }
            } catch { failures.withLock { $0 += 1 } }
        }
        #expect(claims.withLock { $0 } == 1)
        #expect(failures.withLock { $0 } == 0)
        #expect(try await next(reply) == Data([9]))
    }

    @Test func explicitHandoffPrecedesFinishingAndCancelingARefusedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let reply = fixture.request()
        let context = try #require(try await next(fixture.incoming).context)
        let gate = RuntimeSessionGate()
        #expect(gate.began() == 0)
        gate.refuse(.failed(OperationID(), .unauthorizedCaller))
        // This is injected lifetime state, not a signed authentication test. Production must
        // balance its own admission and explicitly hand off before finished/cancel, as here.
        try fixture.send(context, bytes: Data([4]))
        #expect(gate.finished())
        try fixture.server().cancel(reason: "reply context fixture refused")
        #expect(try await next(reply) == Data([4]))
        #expect(gate.began() == nil)
        #expect(try context.takeReply(payload: Data([5]), protocolVersion: fixtureVersion) == nil)
    }
}

private struct Incoming: Sendable {
    let context: RawRuntimeReplyContext?
    let secondCreationRejected: Bool
}

private final class Fixture: Sendable {
    let listener: XPCListener
    let client: XPCSession
    let incoming: AsyncThrowingStream<Incoming, any Error>
    private let holder: SessionHolder

    init() throws {
        let (stream, events) = AsyncThrowingStream<Incoming, any Error>.makeStream()
        incoming = stream
        // The listener owns its session; this separate holder allows deterministic fixture
        // cleanup without global state. XPCSession is SDK-declared Sendable.
        let holder = SessionHolder()
        let listener = XPCListener { request in
            request.accept { session in
                holder.session.withLock { $0 = session }
                return Handler(events: events)
            }
        }
        do { client = try XPCSession(endpoint: listener.endpoint) }
        catch { listener.cancel(); throw error }
        self.listener = listener
        self.holder = holder
    }

    func server() throws -> XPCSession {
        try #require(holder.session.withLock { $0 })
    }

    func request() -> AsyncThrowingStream<Data, any Error> {
        let (stream, answers) = AsyncThrowingStream<Data, any Error>.makeStream()
        client.send(message: XPCDictionary()) { result in
            switch result {
            case .success(let message):
                do {
                    answers.yield(try RawRuntimeFrame.payload(message, expectedVersion: fixtureVersion))
                    answers.finish()
                } catch { answers.finish(throwing: error) }
            case .failure: answers.finish(throwing: FixtureFailure.transport)
            }
        }
        return stream
    }

    func send(_ context: RawRuntimeReplyContext, bytes: Data) throws {
        let reply = try #require(try context.takeReply(payload: bytes, protocolVersion: fixtureVersion))
        try server().send(message: reply)
    }

    func cancel() {
        client.cancel(reason: "reply context fixture completed")
        holder.session.withLock { $0 }?.cancel(reason: "reply context fixture completed")
        listener.cancel()
    }
}

private final class SessionHolder: Sendable {
    let session = Mutex<XPCSession?>(nil)
}

private struct Handler: XPCPeerHandler {
    let events: AsyncThrowingStream<Incoming, any Error>.Continuation

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        let context = RawRuntimeReplyContext(receivedMessage: message)
        let second = RawRuntimeReplyContext(receivedMessage: message)
        events.yield(Incoming(context: context, secondCreationRejected: second == nil))
        return nil // Context was consumed: never let the native API create a second reply.
    }
}

private enum FixtureFailure: Error { case timeout, transport }

private func next<T: Sendable>(_ stream: AsyncThrowingStream<T, any Error>) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try #require(await iterator.next())
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw FixtureFailure.timeout
        }
        defer { group.cancelAll() }
        return try #require(await group.next())
    }
}
