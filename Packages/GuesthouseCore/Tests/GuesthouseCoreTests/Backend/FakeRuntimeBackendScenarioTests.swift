import Foundation
import Testing
@testable import GuesthouseCore

/// Remaining no-I/O scenario assertions retained from #60's basic suite.
@Suite(.timeLimit(.minutes(1))) struct FakeRuntimeBackendScenarioTests {
    let environment = EnvironmentID(), operation = OperationID()

    @Test func successPreservesEveryStageAndFractionBeforeTheFinalStatus() async throws {
        let backend = FakeRuntimeBackend()
        let phases = [ProgressPhase(kind: .startingVM), ProgressPhase(kind: .waitingForNetwork, fraction: 0.5)]
        let status = EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready)
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .succeed(phases: phases, status: status))
        #expect(try await collect(backend.send(.startEnvironment(environment, StartOptions()))) == [
            .accepted(operation), .progress(operation, phases[0]), .progress(operation, phases[1]),
            .status(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready,
                                      inFlightOperation: operation)), .completed(operation)
        ])
        #expect(await backend.status(of: environment) == status)
    }

    @Test func stagedDisconnectionPreservesAcceptanceProgressAndUncertainIdentity() async throws {
        let backend = FakeRuntimeBackend(), phase = ProgressPhase(kind: .copying)
        await backend.useOperationID(operation, forNext: "importXcode")
        await backend.script("importXcode", .disconnect(after: [phase]))
        let handoff = FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app")
        var events = backend.send(.importXcode(environment, handoff)).makeAsyncIterator()
        try #require(try await events.next() == .accepted(operation))
        #expect(try await events.next() == .progress(operation, phase))
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost, operationID: operation, mayHaveMutated: true)) {
            try await events.next()
        }
        #expect(await backend.status(of: environment)?.inFlightOperation == operation)
    }

    @Test(arguments: [false, true])
    func bothQueriesHonorScriptedFailureAndDisconnection(statusQuery: Bool) async throws {
        let backend = FakeRuntimeBackend()
        let request = statusQuery ? RuntimeRequest.environmentStatus(environment) : .runtimeVersion
        await backend.script(request.caseName, .fail(error: .unauthorizedCaller))
        let events = try await collect(backend.send(request))
        try #require(events.count == 1)
        guard case .failed(_, let error) = events[0] else {
            Issue.record("Expected the scripted query failure."); return
        }
        #expect(error == .unauthorizedCaller)
        await backend.script(request.caseName, .disconnect())
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost)) {
            try await collect(backend.send(request))
        }
        #expect(await backend.receivedRequests == [request, request])
    }

    @Test func queriesReturnConfiguredValuesWithoutInventingOperationEvents() async throws {
        let first = RuntimeVersionInfo(serviceVersion: "1.0.0", serviceBuild: "fixture-one")
        let second = RuntimeVersionInfo(serviceVersion: "2.0.0", serviceBuild: "fixture-two")
        let backend = FakeRuntimeBackend(versionInfo: first)
        let status = EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready)
        await backend.setStatus(status)
        #expect(try await collect(backend.send(.runtimeVersion)) == [.runtimeVersion(first)])
        await backend.setVersionInfo(second)
        #expect(try await collect(backend.send(.runtimeVersion)) == [.runtimeVersion(second)])
        #expect(try await collect(backend.send(.environmentStatus(environment))) == [.status(status)])
        #expect(await backend.receivedRequests == [.runtimeVersion, .runtimeVersion, .environmentStatus(environment)])
    }

    @Test func mixedRequestsRemainInSendOrderWhenStreamsAreConsumedInReverse() async throws {
        let backend = FakeRuntimeBackend()
        let requests: [RuntimeRequest] = (0..<20).map {
            $0.isMultiple(of: 2) ? .startEnvironment(environment, StartOptions()) : .stopEnvironment(environment, .force)
        }
        let streams = requests.map { backend.send($0) }
        for stream in streams.reversed() { _ = try await collect(stream) }
        #expect(await backend.receivedRequests == requests)
    }

    @Test func defaultGracefulStopHasOnlyAcceptanceAndCompletion() async throws {
        let backend = FakeRuntimeBackend()
        await backend.useOperationID(operation, forNext: "stopEnvironment")
        #expect(try await collect(backend.send(.stopEnvironment(environment, .graceful(deadline: .seconds(30))))) ==
                [.accepted(operation), .completed(operation)])
    }

    @Test func cancelingAHangingConsumerRecordsOneSyntheticRequestAndClearsStatus() async throws {
        let backend = FakeRuntimeBackend()
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let (finished, continuation) = AsyncStream<RuntimeRequest>.makeStream()
        await backend.observeProducerCompletion { continuation.yield($0) }
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        var events = backend.send(request).makeAsyncIterator()
        try #require(try await events.next() == .accepted(operation))
        let consumer = Task { while try await events.next() != nil {} }
        defer { consumer.cancel() }
        consumer.cancel()
        _ = try? await consumer.value
        var completion = finished.makeAsyncIterator()
        try #require(await completion.next() == request)
        _ = try await collect(backend.send(.environmentStatus(environment)))
        #expect(await backend.receivedRequests == [request, .cancelOperation(operation), .environmentStatus(environment)])
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    private func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
