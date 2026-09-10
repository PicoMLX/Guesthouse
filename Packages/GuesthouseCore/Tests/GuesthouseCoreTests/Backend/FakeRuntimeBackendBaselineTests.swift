import Foundation
import Testing
@testable import GuesthouseCore

/// Retained #60 baseline scenarios; no native session, process, provider or filesystem work.
@Suite(.timeLimit(.minutes(1))) struct FakeRuntimeBackendBaselineTests {
    let environment = EnvironmentID(), operation = OperationID()

    @Test func successRetainsIdentityThroughProgressAndImmutableStatus() async throws {
        let backend = FakeRuntimeBackend()
        let phase = ProgressPhase(kind: .startingVM)
        let status = EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready)
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .succeed(phases: [phase], status: status))
        let request = RuntimeRequest.startEnvironment(environment, StartOptions())
        let events = try await collect(backend.send(request))
        let inFlight = EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready,
                                         inFlightOperation: operation)
        #expect(events == [.accepted(operation), .progress(operation, phase), .status(inFlight), .completed(operation)])
        #expect(await backend.status(of: environment) == status)
        #expect(await backend.receivedRequests == [request])
    }

    @Test func scriptedFailureRetainsItsTypedErrorAndClearsTheOperation() async throws {
        let backend = FakeRuntimeBackend()
        let phase = ProgressPhase(kind: .stoppingVM)
        await backend.useOperationID(operation, forNext: "stopEnvironment")
        await backend.script("stopEnvironment", .fail(after: [phase], error: .guestNotReachable(environment)))
        #expect(try await collect(backend.send(.stopEnvironment(environment, .force))) ==
                [.accepted(operation), .progress(operation, phase), .failed(operation, .guestNotReachable(environment))])
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test func queriesDoNotInventProviderVerificationOrOperationIdentity() async throws {
        let backend = FakeRuntimeBackend()
        let info = RuntimeVersionInfo(serviceVersion: "0.0.0", serviceBuild: "fake")
        #expect(try await collect(backend.send(.runtimeVersion)) == [.runtimeVersion(info)])
        let absent = EnvironmentStatus(environmentID: environment, vm: .notFound, readiness: .checking)
        #expect(try await collect(backend.send(.environmentStatus(environment))) == [.status(absent)])
        #expect(await backend.receivedRequests == [.runtimeVersion, .environmentStatus(environment)])
    }

    @Test func disconnectionDistinguishesQueriesFromAcceptedMutations() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("runtimeVersion", .disconnect())
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost)) {
            try await collect(backend.send(.runtimeVersion))
        }
        await backend.useOperationID(operation, forNext: "importXcode")
        await backend.script("importXcode", .disconnect())
        let handoff = FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app")
        var iterator = backend.send(.importXcode(environment, handoff)).makeAsyncIterator()
        try #require(try await iterator.next() == .accepted(operation))
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost, operationID: operation, mayHaveMutated: true)) {
            try await iterator.next()
        }
        #expect(await backend.status(of: environment)?.inFlightOperation == operation)
    }

    @Test func explicitCancellationHasItsOwnAcknowledgmentAndTheTargetStillTerminates() async throws {
        let backend = FakeRuntimeBackend(), acknowledgment = OperationID()
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        var iterator = backend.send(.startEnvironment(environment, StartOptions())).makeAsyncIterator()
        try #require(try await iterator.next() == .accepted(operation))
        await backend.useOperationID(acknowledgment, forNext: "cancelOperation")
        #expect(try await collect(backend.send(.cancelOperation(operation))) == [.completed(acknowledgment)])
        #expect(try await iterator.next() == .failed(operation, .canceled))
        #expect(try await iterator.next() == nil)
        #expect(await backend.receivedRequests == [.startEnvironment(environment, StartOptions()), .cancelOperation(operation)])
    }

    private func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
