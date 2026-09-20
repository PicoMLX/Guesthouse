import Testing
@testable import GuesthouseCore

/// Regression coverage for #180's cancellation status and producer-completion ordering.
@Suite(.timeLimit(.minutes(1))) struct FakeRuntimeBackendCancellationOrderingTests {
    @Test(arguments: [false, true])
    func scriptedCancellationCannotHideALiveTarget(unrelatedID: Bool) async throws {
        let backend = FakeRuntimeBackend(), environment = EnvironmentID(), operation = OperationID()
        let (entered, arrival) = AsyncStream<Void>.makeStream()
        let (release, gate) = AsyncStream<Void>.makeStream()
        defer { arrival.finish(); gate.finish() }
        await backend.setEventPause {
            arrival.yield(())
            var wait = release.makeAsyncIterator()
            _ = await wait.next()
        }
        await backend.useOperationID(operation, forNext: "startEnvironment")
        var target = backend.send(.startEnvironment(environment, StartOptions())).makeAsyncIterator()
        try #require(try await target.next() == .accepted(operation))
        var arrivalEvents = entered.makeAsyncIterator()
        try #require(await arrivalEvents.next() != nil)
        // Keep the target at its terminal boundary; subsequent requests do not wait there.
        await backend.setEventPause {}
        await backend.script("cancelOperation", .succeed(status: EnvironmentStatus(
            environmentID: environment, vm: .running, readiness: .checking,
            inFlightOperation: unrelatedID ? OperationID() : nil
        )))
        for try await _ in backend.send(.cancelOperation(operation)) {}
        #expect(await backend.status(of: environment)?.inFlightOperation == operation)

        gate.finish()
        #expect(try await target.next() == .failed(operation, .canceled))
        #expect(try await target.next() == nil)
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test(arguments: ["success", "failure", "disconnect", "hang"])
    func producerCompletionIncludesImplicitCancellation(scenario: String) async throws {
        let backend = FakeRuntimeBackend(), environment = EnvironmentID(), operation = OperationID()
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let (finished, completion) = AsyncStream<RuntimeRequest>.makeStream()
        let (release, gate) = AsyncStream<Void>.makeStream()
        defer { completion.finish(); gate.finish() }
        await backend.observeProducerCompletion { completion.yield($0) }
        await backend.setEventPause {
            var wait = release.makeAsyncIterator()
            _ = await wait.next() // Consumer cancellation releases this suspension.
        }
        switch scenario {
        case "failure": await backend.script("startEnvironment", .fail(error: .unauthorizedCaller))
        case "disconnect": await backend.script("startEnvironment", .disconnect())
        case "hang": await backend.script("startEnvironment", .hang)
        default: break
        }
        await backend.useOperationID(operation, forNext: "startEnvironment")
        var events = backend.send(request).makeAsyncIterator()
        try #require(try await events.next() == .accepted(operation))
        let consumer = Task { while try await events.next() != nil {} }
        defer { consumer.cancel() }
        consumer.cancel()
        _ = try? await consumer.value
        var producer = finished.makeAsyncIterator()
        try #require(await producer.next() == request)
        // No extra query to drain pending tickets: completion itself must include the record.
        #expect(await backend.receivedRequests == [request, .cancelOperation(operation)])
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }
}
