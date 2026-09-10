import Foundation
import Testing
@testable import GuesthouseCore

/// Retained #60 reservation/replay regressions, synchronized on the fake producer's cleanup.
/// Each case owns its backend and observers; no clocks, polling, host work or shared state.
@Suite(.timeLimit(.minutes(1))) struct FakeRuntimeBackendCancellationTests {
    let environment = EnvironmentID(), operation = OperationID()

    @Test func aFailedCancellationRequestReleasesItsReservation() async throws {
        let (backend, completions) = await observedBackend()
        var finished = completions.makeAsyncIterator()
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let consumer = try await start(backend, environment: environment, operation: operation)
        defer { consumer.cancel() }
        await backend.script("cancelOperation", .fail(error: .invalidRequest(.unsupportedOperation)))
        #expect(try await collect(backend.send(.cancelOperation(operation))) ==
                [.failed(operation, .invalidRequest(.unsupportedOperation))])

        consumer.cancel()
        _ = try? await consumer.value
        try await waitFor(request, in: &finished)
        // Taking a query ticket after cleanup drains the earlier synthetic-cancellation ticket.
        _ = try await collect(backend.send(.environmentStatus(environment)))
        #expect(await backend.receivedRequests == [
            request, .cancelOperation(operation), .cancelOperation(operation), .environmentStatus(environment)
        ])
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test func aSuppressedCancellationReplaysBeforeRequestsSentAfterIt() async throws {
        let (backend, completions) = await observedBackend()
        var finished = completions.makeAsyncIterator()
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let consumer = try await start(backend, environment: environment, operation: operation)
        defer { consumer.cancel() }
        await backend.script("cancelOperation", .hang)
        let pending = backend.send(.cancelOperation(operation)) // Reservation is synchronous.
        let canceller = Task { try await collect(pending) }
        defer { canceller.cancel() }

        consumer.cancel()
        _ = try? await consumer.value
        try await waitFor(request, in: &finished)
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
        _ = try await collect(backend.send(.environmentStatus(environment)))
        #expect(await backend.receivedRequests == [
            request, .cancelOperation(operation), .environmentStatus(environment)
        ])

        canceller.cancel()
        _ = try? await canceller.value
        try await waitFor(.cancelOperation(operation), in: &finished)
        #expect(await backend.receivedRequests == [
            request, .cancelOperation(operation), .cancelOperation(operation), .environmentStatus(environment)
        ])
    }

    @Test(arguments: [false, true])
    func twoSuppressionsKeepTheirOrderRegardlessOfReservationReleaseOrder(reverse: Bool) async throws {
        let (backend, completions) = await observedBackend()
        var finished = completions.makeAsyncIterator()
        let secondEnvironment = EnvironmentID(), secondOperation = OperationID()
        let firstRequest = RuntimeRequest.startEnvironment(environment, StartOptions())
        let secondRequest = RuntimeRequest.startEnvironment(secondEnvironment, StartOptions())
        let first = try await start(backend, environment: environment, operation: operation)
        defer { first.cancel() }
        let second = try await start(backend, environment: secondEnvironment, operation: secondOperation)
        defer { second.cancel() }
        await backend.script("cancelOperation", .hang)
        let firstPending = backend.send(.cancelOperation(operation))
        let firstCanceller = Task { try await collect(firstPending) }
        defer { firstCanceller.cancel() }
        let secondPending = backend.send(.cancelOperation(secondOperation))
        let secondCanceller = Task { try await collect(secondPending) }
        defer { secondCanceller.cancel() }

        first.cancel()
        _ = try? await first.value
        try await waitFor(firstRequest, in: &finished)
        second.cancel()
        _ = try? await second.value
        try await waitFor(secondRequest, in: &finished)
        _ = try await collect(backend.send(.environmentStatus(environment)))
        #expect(await backend.receivedRequests == [
            firstRequest, secondRequest, .cancelOperation(operation), .cancelOperation(secondOperation),
            .environmentStatus(environment)
        ])

        let releases = [(firstCanceller, operation), (secondCanceller, secondOperation)]
        for (canceller, id) in reverse ? Array(releases.reversed()) : releases {
            canceller.cancel()
            _ = try? await canceller.value
            try await waitFor(.cancelOperation(id), in: &finished)
        }
        #expect(await backend.receivedRequests == [
            firstRequest, secondRequest, .cancelOperation(operation), .cancelOperation(secondOperation),
            .cancelOperation(operation), .cancelOperation(secondOperation), .environmentStatus(environment)
        ])
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
        #expect(await backend.status(of: secondEnvironment)?.inFlightOperation == nil)
    }

    @Test func releasingOneReservationDoesNotReleaseAnOverlappingRequest() async throws {
        let (backend, completions) = await observedBackend()
        var finished = completions.makeAsyncIterator()
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let consumer = try await start(backend, environment: environment, operation: operation)
        defer { consumer.cancel() }
        await backend.script("cancelOperation", .hang)
        let pending = backend.send(.cancelOperation(operation))
        let canceller = Task { try await collect(pending) }
        defer { canceller.cancel() }
        await backend.script("cancelOperation", .disconnect())
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost, operationID: operation, mayHaveMutated: true)) {
            try await collect(backend.send(.cancelOperation(operation)))
        }
        try await waitFor(.cancelOperation(operation), in: &finished)

        consumer.cancel()
        _ = try? await consumer.value
        try await waitFor(request, in: &finished)
        _ = try await collect(backend.send(.environmentStatus(environment)))
        #expect(await backend.receivedRequests == [
            request, .cancelOperation(operation), .cancelOperation(operation), .environmentStatus(environment)
        ])
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)

        canceller.cancel()
        _ = try? await canceller.value
        try await waitFor(.cancelOperation(operation), in: &finished)
        #expect(await backend.receivedRequests == [
            request, .cancelOperation(operation), .cancelOperation(operation), .cancelOperation(operation),
            .environmentStatus(environment)
        ])
    }

    @Test func explicitCancellationIsRecordedOnceEvenWhenTheConsumerAlsoStops() async throws {
        let (backend, completions) = await observedBackend()
        var finished = completions.makeAsyncIterator()
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let consumer = try await start(backend, environment: environment, operation: operation)
        defer { consumer.cancel() }
        _ = try await collect(backend.send(.cancelOperation(operation)))
        consumer.cancel()
        _ = try? await consumer.value
        try await waitFor(request, in: &finished)
        _ = try await collect(backend.send(.environmentStatus(environment)))
        #expect(await backend.receivedRequests == [
            request, .cancelOperation(operation), .environmentStatus(environment)
        ])
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test func successfulCancellationKeepsSuppressionWhenAnotherReservationFailsLater() async throws {
        let (backend, completions) = await observedBackend()
        var finished = completions.makeAsyncIterator()
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let consumer = try await start(backend, environment: environment, operation: operation)
        defer { consumer.cancel() }
        await backend.script("cancelOperation", .hang)
        let pending = backend.send(.cancelOperation(operation))
        let canceller = Task { try await collect(pending) }
        defer { canceller.cancel() }
        consumer.cancel()
        _ = try? await consumer.value
        try await waitFor(request, in: &finished)

        await backend.script("cancelOperation", .succeed())
        _ = try await collect(backend.send(.cancelOperation(operation)))
        try await waitFor(.cancelOperation(operation), in: &finished)
        canceller.cancel()
        _ = try? await canceller.value
        try await waitFor(.cancelOperation(operation), in: &finished)
        _ = try await collect(backend.send(.environmentStatus(environment)))
        #expect(await backend.receivedRequests == [
            request, .cancelOperation(operation), .cancelOperation(operation), .environmentStatus(environment)
        ])
    }

    @Test func aScriptedPostCancellationStatusCannotRestoreTheCanceledOperation() async throws {
        let backend = FakeRuntimeBackend()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready,
                                                  inFlightOperation: operation))
        await backend.script("cancelOperation", .succeed(status: EnvironmentStatus(
            environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: operation
        )))
        _ = try await collect(backend.send(.cancelOperation(operation)))
        #expect(await backend.status(of: environment) ==
                EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready))
    }

    private func observedBackend() async -> (FakeRuntimeBackend, AsyncStream<RuntimeRequest>) {
        let backend = FakeRuntimeBackend()
        let (stream, continuation) = AsyncStream<RuntimeRequest>.makeStream()
        await backend.observeProducerCompletion { request in continuation.yield(request) }
        return (backend, stream)
    }

    private func start(_ backend: FakeRuntimeBackend, environment: EnvironmentID,
                       operation: OperationID) async throws -> Task<Void, any Error> {
        await backend.script("startEnvironment", .hang)
        await backend.useOperationID(operation, forNext: "startEnvironment")
        var iterator = backend.send(.startEnvironment(environment, StartOptions())).makeAsyncIterator()
        try #require(try await iterator.next() == .accepted(operation))
        return Task { while try await iterator.next() != nil {} }
    }

    private func waitFor(_ request: RuntimeRequest,
                         in iterator: inout AsyncStream<RuntimeRequest>.Iterator) async throws {
        while let finished = await iterator.next() {
            if finished == request { return }
        }
        try #require(Bool(false), "The fake producer did not finish before its observer was cancelled.")
    }

    private func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
