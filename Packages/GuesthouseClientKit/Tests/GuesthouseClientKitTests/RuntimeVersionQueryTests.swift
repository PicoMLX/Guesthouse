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

    @Test func suppliedDeadlineBeyondTenSecondsIsTheOnlyTimeout() async {
        let session = QuerySession([])
        defer { session.releaseReply() }
        // Intentionally crosses the old hidden ten-second timer; an immediate fake
        // deadline cannot expose that competing clock. No timing-based state polling.
        let value = await run(session, deadline: { try await ContinuousClock().sleep(for: .seconds(11)) })
        #expect(value == .failure(.timedOut))
        #expect(session.cancellations.withLock { $0 } == 1)
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

@Suite(.timeLimit(.minutes(1))) struct RuntimeHostPreflightQueryTests {
    static let report = PreflightCheck.run(snapshot: HostProbeSnapshot())
    static let id = OperationID()
    static let cases: [(RuntimeEvent, RuntimeHostPreflightQuery.Outcome)] = [
        (.hostPreflight(report), .success(report)),
        (.failed(id, .invalidRequest(.unsupportedOperation)), .failure(.runtime(.invalidRequest(.unsupportedOperation)))),
        (.runtimeVersion(.init(serviceVersion: "1", serviceBuild: "1")), .failure(.connection(.init(cause: .malformedResponse)))),
        (.accepted(id), .failure(.connection(.init(cause: .malformedResponse, operationID: id)))),
        (.hostPreflight(.init(results: [], storage: report.storage, powerSource: .unknown, checkedAt: report.checkedAt)),
         .failure(.connection(.init(cause: .malformedResponse)))),
    ]

    @Test(arguments: cases)
    func onlyACompleteOwningReportSucceeds(event: RuntimeEvent, expected: RuntimeHostPreflightQuery.Outcome) async {
        let session = QuerySession([.success(event)], expectedRequest: .hostPreflight)
        defer { session.releaseReply() }
        #expect(await runPreflight(session) == expected)
        #expect(session.cancellations.withLock { $0 } == 1)
        #expect(session.sends.withLock { $0 } == 1)
    }

    @Test(arguments: [RuntimeSessionFailure.Cause.connectionLost, .malformedResponse,
                      .oversizedResponse, .protocolMismatch(service: 12)])
    func nativeFailureRemainsReadOnlyAndKeepsItsCause(cause: RuntimeSessionFailure.Cause) async {
        let session = QuerySession([.failure(.init(cause: cause))], expectedRequest: .hostPreflight)
        defer { session.releaseReply() }
        #expect(await runPreflight(session) == .failure(.connection(.init(cause: cause))))
        #expect(session.cancellations.withLock { $0 } == 1)
    }

    @Test func setupFailureHasOnlyGuesthouseOwnedGuidance() async {
        let value = await RuntimeHostPreflightQuery.perform(connect: { _, _ in
            throw NSError(domain: "private-marker", code: 1)
        }, deadline: waitForCancellation)
        #expect(value == .failure(.connection(.init(cause: .connectionLost))))
        if case .failure(let error) = value {
            #expect(!(error.userMessage + error.recoveryMessage).contains("private-marker"))
        }
    }

    @Test func aBlockedReportStillFinishesAndCancelsTheDeadline() async {
        let canceled = Mutex(false)
        let session = QuerySession([.success(.hostPreflight(Self.report))], expectedRequest: .hostPreflight)
        defer { session.releaseReply() }
        let result = await runPreflight(session, deadline: {
            try await withTaskCancellationHandler { try await waitForCancellation() }
            onCancel: { canceled.withLock { $0 = true } }
        })
        #expect(result == .success(Self.report))
        #expect(!Self.report.canProceed)
        #expect(canceled.withLock { $0 })
        #expect(session.cancellations.withLock { $0 } == 1)
    }

    @Test(arguments: [0, 11])
    func onlyTheSuppliedDeadlineTimesOutAndLateRepliesNeverReplay(seconds: Int) async {
        let session = QuerySession([], expectedRequest: .hostPreflight)
        defer { session.releaseReply() }
        // Eleven seconds deliberately crosses the disabled inner client's ten-second timer.
        #expect(await runPreflight(session, deadline: {
            try await ContinuousClock().sleep(for: .seconds(seconds))
        }) == .failure(.timedOut))
        #expect(session.cancellations.withLock { $0 } == 1)
        session.answerLate(.success(.hostPreflight(Self.report)))
        #expect(session.sends.withLock { $0 } == 1)
    }

    @Test func cancelingAPendingCheckAwaitsCleanupAndNeverReplays() async {
        let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let session = QuerySession([], expectedRequest: .hostPreflight, didSend: { signal.yield(()); signal.finish() })
        defer { session.releaseReply(); signal.finish() }
        let task = Task { await runPreflight(session) }
        for await _ in started { break }
        task.cancel()
        #expect(await task.value == .failure(.canceled))
        #expect(session.cancellations.withLock { $0 } == 1)
        session.answerLate(.success(.hostPreflight(Self.report)))
        #expect(session.sends.withLock { $0 } == 1)
    }

    @Test func anAlreadyCanceledCheckDoesNotCreateASession() async {
        let (gate, finish) = AsyncStream<Void>.makeStream()
        defer { finish.finish() }
        let task = Task {
            for await _ in gate { break }
            return await RuntimeHostPreflightQuery.perform(connect: { _, _ in
                Issue.record("Canceled preflight must not connect.")
                return QuerySession([], expectedRequest: .hostPreflight)
            }, deadline: waitForCancellation)
        }
        task.cancel()
        #expect(await task.value == .failure(.canceled))
    }
}

private func runPreflight(_ session: QuerySession,
                         deadline: @escaping @Sendable () async throws -> Void = waitForCancellation) async -> RuntimeHostPreflightQuery.Outcome {
    await RuntimeHostPreflightQuery.perform(connect: { _, _ in session }, deadline: deadline)
}
private func waitForCancellation() async throws { try await ContinuousClock().sleep(for: .seconds(60)) }
private func run(_ session: QuerySession,
                 deadline: @escaping @Sendable () async throws -> Void = waitForCancellation) async -> RuntimeVersionQuery.Outcome {
    await RuntimeVersionQuery.perform(connect: { _, _ in session }, deadline: deadline)
}

private final class QuerySession: RuntimeClientSession {
    typealias Reply = @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void
    let responses: [Result<RuntimeEvent, RuntimeSessionFailure>]
    let expectedRequest: RuntimeRequest
    let didSend: @Sendable () -> Void
    let cancellations = Mutex(0), sends = Mutex(0), reply = Mutex<Reply?>(nil)
    init(_ responses: [Result<RuntimeEvent, RuntimeSessionFailure>], expectedRequest: RuntimeRequest = .runtimeVersion,
         didSend: @escaping @Sendable () -> Void = {}) {
        self.responses = responses; self.expectedRequest = expectedRequest; self.didSend = didSend
    }
    func activate() throws {}
    func cancel() { cancellations.withLock { $0 += 1 } }
    func send(_ payload: Data, reply: @escaping Reply) {
        do { let request = try RequestValidator.decode(payload); #expect(request.request == expectedRequest) }
        catch { Issue.record("The check must send its expected valid read-only request.") }
        sends.withLock { $0 += 1 }
        self.reply.withLock { $0 = reply }
        didSend()
        for response in responses { reply(response) }
    }
    func answerLate(_ value: Result<RuntimeEvent, RuntimeSessionFailure>) { reply.withLock { $0 }?(value) }
    func releaseReply() { reply.withLock { $0 = nil } }
}
