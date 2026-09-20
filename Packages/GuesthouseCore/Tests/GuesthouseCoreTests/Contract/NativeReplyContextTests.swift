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
        let firstIncoming = try await fixture.nextIncoming()
        let second = fixture.request()
        let secondIncoming = try await fixture.nextIncoming()
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
        let oneWay = try await fixture.nextIncoming()
        #expect(oneWay.context == nil)
        #expect(oneWay.secondCreationRejected)
        let reply = fixture.request()
        let context = try #require(try await fixture.nextIncoming().context)
        try fixture.send(context, bytes: Data([7]))
        #expect(try await next(reply) == Data([7]))
    }

    @Test(arguments: [0, RawRuntimeFrame.maximumPayloadBytes + 1])
    func invalidEncodingPreservesTheContextForATypedFailure(_ count: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let reply = fixture.request()
        let context = try #require(try await fixture.nextIncoming().context)
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
        let context = try #require(try await fixture.nextIncoming().context)
        let bytes = Data(repeating: 32, count: RawRuntimeFrame.maximumPayloadBytes)
        try fixture.send(context, bytes: bytes)
        #expect(try await next(reply) == bytes)
    }

    @Test func aClaimedReplyCannotBeReclaimedWithoutSuccessfulDelivery() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        _ = fixture.request()
        let context = try #require(try await fixture.nextIncoming().context)
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
        let context = try #require(try await fixture.nextIncoming().context)
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
        let context = try #require(try await fixture.nextIncoming().context)
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

    @Test func deadlineCancellationReportsOnlyTheTimeout() async {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        defer { continuation.finish() }
        await #expect(throws: FixtureFailure.timeout(.awaitingReply)) {
            _ = try await next(stream, timeout: .milliseconds(10))
        }
    }

    @Test func anUnexpectedEndStillFailsTheWait() async {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.finish()
        await #expect(throws: FixtureFailure.streamEnded) {
            _ = try await next(stream)
        }
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
            holder.progress.value.withLock { $0 = .acceptingSession }
            let handler = Handler(events: events, progress: holder.progress)
            // Match the raw-dictionary registration used by the native frame/session
            // fixtures. This suite tests retained reply contexts, not peer-handler setup.
            let (decision, session) = request.accept(
                incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                    handler.handleIncomingRequest(message)
                }, cancellationHandler: { error in handler.handleCancellation(error: error) }
            )
            holder.session.withLock { $0 = session }
            holder.progress.value.withLock { $0 = .awaitingRequest }
            return decision
        }
        do {
            client = try XPCSession(endpoint: listener.endpoint, cancellationHandler: { _ in
                events.finish(throwing: FixtureFailure.clientCancelled)
            })
        }
        catch { listener.cancel(); throw error }
        self.listener = listener
        self.holder = holder
    }

    func nextIncoming() async throws -> Incoming {
        try await next(incoming, progress: holder.progress)
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
    let progress = ProgressProbe()
}

private final class ProgressProbe: Sendable {
    let value = Mutex(FixtureProgress.awaitingConnection)
}

private struct Handler: Sendable {
    let events: AsyncThrowingStream<Incoming, any Error>.Continuation
    let progress: ProgressProbe

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        progress.value.withLock { $0 = .creatingFirstContext }
        let context = RawRuntimeReplyContext(receivedMessage: message)
        progress.value.withLock { $0 = .checkingSecondContext }
        let second = RawRuntimeReplyContext(receivedMessage: message)
        progress.value.withLock { $0 = .deliveringIncoming }
        events.yield(Incoming(context: context, secondCreationRejected: second == nil))
        return nil // Context was consumed: never let the native API create a second reply.
    }

    func handleCancellation(error: XPCRichError) {
        events.finish(throwing: FixtureFailure.serverCancelled)
    }
}

private enum FixtureProgress: Sendable, Equatable {
    case awaitingConnection, acceptingSession, awaitingRequest, creatingFirstContext, checkingSecondContext
    case deliveringIncoming, awaitingReply
}
private enum FixtureFailure: Error, Equatable {
    case timeout(FixtureProgress), transport, clientCancelled, serverCancelled, streamEnded
}

private func next<T: Sendable>(
    _ stream: AsyncThrowingStream<T, any Error>, progress: ProgressProbe? = nil,
    timeout: Duration = .seconds(5)
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            let value = try await iterator.next()
            // Losing the deadline race cancels next(), which legitimately returns nil.
            // Do not turn that cleanup into a second, misleading Testing issue.
            try Task.checkCancellation()
            guard let value else { throw FixtureFailure.streamEnded }
            return value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FixtureFailure.timeout(progress?.value.withLock { $0 } ?? .awaitingReply)
        }
        defer { group.cancelAll() }
        return try #require(await group.next())
    }
}
