import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseClientKit

@Suite(.timeLimit(.minutes(1))) struct RuntimeVersionQueryTests {
    static let info = RuntimeVersionInfo(serviceVersion: "1.0", serviceBuild: "1")
    static let id = OperationID()
    static let cases: [(RuntimeEvent, RuntimeVersionQuery.Outcome)] = [
        (.runtimeVersion(info), .success(info)),
        (.runtimeVersion(.init(serviceVersion: "1", serviceBuild: "1", protocolVersion: .init(11))),
         .failure(.connection(.init(cause: .protocolMismatch(service: 11))))),
        (.failed(id, .unauthorizedCaller), .failure(.runtime(.unauthorizedCaller))),
        (.accepted(id), .failure(.connection(.init(cause: .malformedResponse, operationID: id)))),
        (.completed(id), .failure(.connection(.init(cause: .malformedResponse, operationID: id)))),
        (.progress(id, .init(kind: .copying)), .failure(.connection(.init(cause: .malformedResponse, operationID: id)))),
        (.diagnostic(.init(operation: .runtimeRequest, outcome: .started, operationID: id.uuid)),
         .failure(.connection(.init(cause: .malformedResponse, operationID: id)))),
        (.status(.init(environmentID: EnvironmentID(), vm: .stopped, readiness: .checking)),
         .failure(.connection(.init(cause: .malformedResponse)))),
    ]

    @Test(arguments: cases)
    func onlyTheExpectedResponseIsSuccess(event: RuntimeEvent, expected: RuntimeVersionQuery.Outcome) async {
        let session = QuerySession([.success(event)])
        defer { session.releaseReply() }
        #expect(await run(session) == expected)
        #expect(session.cancellations.withLock { $0 } == 1)
        if case .failure(let failure) = expected { #expect(!failure.recoveryMessage.isEmpty) }
    }

    @Test(arguments: [RuntimeSessionFailure.Cause.connectionLost, .malformedResponse,
                       .oversizedResponse, .protocolMismatch(service: 11)])
    func nativeFailureKeepsItsCause(cause: RuntimeSessionFailure.Cause) async {
        let session = QuerySession([.failure(.init(cause: cause))])
        defer { session.releaseReply() }
        #expect(await run(session) == .failure(.connection(.init(cause: cause))))
        #expect(session.cancellations.withLock { $0 } == 1)
    }

    @Test func setupFailureNeverExposesTheUnderlyingError() async {
        let value = await RuntimeVersionQuery.perform(connect: { _, _ in
            throw NSError(domain: "private-marker", code: 1)
        }, deadline: waitForCancellation)
        #expect(value == .failure(.connection(.init(cause: .connectionLost))))
        if case .failure(let error) = value {
            #expect(!(error.userMessage + error.recoveryMessage).contains("private-marker"))
        }
    }

    @Test func oneReplyFinishesAndCancelsTheDeadline() async {
        let canceled = Mutex(false)
        let session = QuerySession([.success(.runtimeVersion(Self.info)), .success(.accepted(Self.id))])
        defer { session.releaseReply() }
        let value = await run(session, deadline: {
            try await withTaskCancellationHandler {
                try await waitForCancellation()
            } onCancel: { canceled.withLock { $0 = true } }
        })
        #expect(value == .success(Self.info))
        #expect(canceled.withLock { $0 })
        #expect(session.sends.withLock { $0 } == 1)
    }

    @Test func timeoutDisposesTheConnectionAndDoesNotReplay() async {
        let session = QuerySession([])
        defer { session.releaseReply() }
        #expect(await run(session, deadline: {}) == .failure(.timedOut))
        #expect(session.cancellations.withLock { $0 } == 1)
        session.answerLate(.success(.runtimeVersion(Self.info)))
        #expect(session.sends.withLock { $0 } == 1)
    }

    @Test func cancelingAPendingCheckDisposesItWithoutWaitingForTheTimeout() async {
        let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let session = QuerySession([], didSend: { signal.yield(()); signal.finish() })
        defer { session.releaseReply(); signal.finish() }
        let task = Task { await run(session) }
        for await _ in started { break }
        task.cancel()
        #expect(await task.value == .failure(.canceled))
        #expect(session.cancellations.withLock { $0 } == 1)
        session.answerLate(.success(.accepted(Self.id)))
        #expect(session.sends.withLock { $0 } == 1)
    }

    @Test func anAlreadyCanceledCheckNeverConnects() async {
        let (gate, finish) = AsyncStream<Void>.makeStream()
        let connections = Mutex(0)
        let session = QuerySession([])
        let task = Task {
            for await _ in gate { break }
            return await RuntimeVersionQuery.perform(connect: { _, _ in
                connections.withLock { $0 += 1 }; return session
            }, deadline: waitForCancellation)
        }
        task.cancel()
        #expect(await task.value == .failure(.canceled))
        finish.finish()
        #expect(connections.withLock { $0 } == 0)
    }
}

private func waitForCancellation() async throws { try await ContinuousClock().sleep(for: .seconds(60)) }
private func run(_ session: QuerySession,
                 deadline: @escaping @Sendable () async throws -> Void = waitForCancellation) async -> RuntimeVersionQuery.Outcome {
    await RuntimeVersionQuery.perform(connect: { _, _ in session }, deadline: deadline)
}

private final class QuerySession: RuntimeClientSession {
    typealias Reply = @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void
    let responses: [Result<RuntimeEvent, RuntimeSessionFailure>]
    let didSend: @Sendable () -> Void
    let cancellations = Mutex(0), sends = Mutex(0), reply = Mutex<Reply?>(nil)
    init(_ responses: [Result<RuntimeEvent, RuntimeSessionFailure>], didSend: @escaping @Sendable () -> Void = {}) {
        self.responses = responses; self.didSend = didSend
    }
    func activate() throws {}
    func cancel() { cancellations.withLock { $0 += 1 } }
    func send(_ payload: Data, reply: @escaping Reply) {
        do { let request = try RequestValidator.decode(payload); #expect(request.request == .runtimeVersion) }
        catch { Issue.record("The connection check must send a valid read-only version request.") }
        sends.withLock { $0 += 1 }
        self.reply.withLock { $0 = reply }
        didSend()
        for response in responses { reply(response) }
    }
    func answerLate(_ value: Result<RuntimeEvent, RuntimeSessionFailure>) { reply.withLock { $0 }?(value) }
    func releaseReply() { reply.withLock { $0 = nil } }
}
