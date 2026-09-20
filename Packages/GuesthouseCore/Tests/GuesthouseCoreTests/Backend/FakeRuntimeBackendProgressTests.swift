import Foundation
import Testing
@testable import GuesthouseCore

/// Retained #60 in-progress assertions use a one-shot event gate, never elapsed-time guesses.
@Suite(.timeLimit(.minutes(1))) struct FakeRuntimeBackendProgressTests {
    let environment = EnvironmentID(), operation = OperationID()
    let observedAt = Date(timeIntervalSince1970: 100)

    enum CancellationPoint: Sendable, Equatable {
        case beforeProgress, afterProgress, beforeDisconnection

        var scenario: FakeRuntimeBackend.Scenario {
            switch self {
            case .beforeProgress, .afterProgress:
                .succeed(phases: [ProgressPhase(kind: .startingVM), ProgressPhase(kind: .waitingForNetwork)])
            case .beforeDisconnection: .disconnect()
            }
        }
        var pause: Int { self == .afterProgress ? 2 : 1 }
    }

    @Test(arguments: [CancellationPoint.beforeProgress, .afterProgress, .beforeDisconnection])
    func consumerCancellationClearsTheOperationAtTheHeldBoundary(_ point: CancellationPoint) async throws {
        let backend = FakeRuntimeBackend(), gate = OneShotPause(on: point.pause)
        defer { gate.release() }
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let (finished, continuation) = AsyncStream<RuntimeRequest>.makeStream()
        await backend.observeProducerCompletion { continuation.yield($0) }
        await backend.setEventPause { await gate.pause() }
        await backend.setStatus(status(operation: operation))
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", point.scenario)
        let consumer = Task { try await collect(backend.send(request)) }
        defer { consumer.cancel() }
        try await gate.waitUntilBlocked()
        #expect(await backend.status(of: environment) == status(operation: operation))

        consumer.cancel()
        _ = try? await consumer.value
        var completion = finished.makeAsyncIterator()
        try #require(await completion.next() == request)
        _ = try await collect(backend.send(.environmentStatus(environment)))
        #expect(await backend.receivedRequests == [request, .cancelOperation(operation), .environmentStatus(environment)])
        #expect(await backend.status(of: environment) == status())
    }

    @Test func cancellationDuringTheTerminalPauseEmitsCanceledInsteadOfCompleted() async throws {
        let backend = FakeRuntimeBackend(), gate = OneShotPause(on: 1)
        defer { gate.release() }
        await backend.setEventPause { await gate.pause() }
        await backend.setStatus(status(operation: operation))
        await backend.useOperationID(operation, forNext: "startEnvironment")
        var events = backend.send(.startEnvironment(environment, StartOptions())).makeAsyncIterator()
        try #require(try await events.next() == .accepted(operation))
        try await gate.waitUntilBlocked()

        let acknowledgment = OperationID()
        await backend.useOperationID(acknowledgment, forNext: "cancelOperation")
        #expect(try await collect(backend.send(.cancelOperation(operation))) == [.completed(acknowledgment)])
        gate.release()
        #expect(try await events.next() == .failed(operation, .canceled))
        #expect(try await events.next() == nil)
        #expect(await backend.status(of: environment) == status())
    }

    @Test func emittedAndQueriedStatusKeepTheOperationUntilItsTerminalEvent() async throws {
        let backend = FakeRuntimeBackend(), gate = OneShotPause(on: 2)
        defer { gate.release() }
        await backend.setEventPause { await gate.pause() }
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .succeed(status: status()))
        var events = backend.send(.startEnvironment(environment, StartOptions())).makeAsyncIterator()
        try #require(try await events.next() == .accepted(operation))
        try #require(try await events.next() == .status(status(operation: operation)))
        try await gate.waitUntilBlocked()
        #expect(await backend.status(of: environment) == status(operation: operation))
        #expect(try await collect(backend.send(.environmentStatus(environment))) == [.status(status(operation: operation))])
        gate.release()
        #expect(try await events.next() == .completed(operation))
        #expect(try await events.next() == nil)
        #expect(await backend.status(of: environment) == status())
    }

    @Test func acceptingAnUnseededOperationPreservesExistingStatusUntilCancellation() async throws {
        let backend = FakeRuntimeBackend()
        await backend.setStatus(status())
        await backend.script("stopEnvironment", .hang)
        var events = backend.send(.stopEnvironment(environment, .force)).makeAsyncIterator()
        let accepted = try #require(try await events.next())
        guard case .accepted(let id) = accepted else {
            Issue.record("Expected an accepted operation."); return
        }
        #expect(await backend.status(of: environment) == status(operation: id))
        #expect(try await collect(backend.send(.environmentStatus(environment))) == [.status(status(operation: id))])
        _ = try await collect(backend.send(.cancelOperation(id)))
        #expect(try await events.next() == .failed(id, .canceled))
        #expect(try await events.next() == nil)
        #expect(await backend.status(of: environment) == status())
    }

    private func status(operation: OperationID? = nil) -> EnvironmentStatus {
        EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready,
                          inFlightOperation: operation, reconciledAt: observedAt)
    }

    private func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

/// Only one chosen pause blocks. Later queries/cancellations can proceed while it is held.
/// AsyncStream supplies cancellation-aware suspension; no task/continuation is left polling.
private actor OneShotPause {
    private var remaining: Int
    private let reached = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let released = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    init(on pause: Int) { remaining = pause }

    func pause() async {
        guard remaining > 0 else { return }
        remaining -= 1
        guard remaining == 0 else { return }
        reached.continuation.yield(())
        reached.continuation.finish()
        var release = released.stream.makeAsyncIterator()
        _ = await release.next()
    }

    nonisolated func waitUntilBlocked() async throws {
        var arrival = reached.stream.makeAsyncIterator()
        try #require(await arrival.next() != nil)
    }

    nonisolated func release() {
        released.continuation.yield(())
        released.continuation.finish()
    }
}
