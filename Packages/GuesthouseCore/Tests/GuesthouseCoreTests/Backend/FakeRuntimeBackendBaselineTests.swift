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

    @Test func hostPreflightAnswersWithTheScriptedReportAndNeverAnOperation() async throws {
        let backend = FakeRuntimeBackend()
        // Unscripted, the fake reports a host that can proceed, so a preview or a wizard test
        // that never scripts one is not blocked by an answer it did not ask for.
        let ready = try #require(try await collect(backend.send(.hostPreflight)).first)
        guard case .hostPreflight(let report) = ready else { Issue.record("expected a report, got \(ready)"); return }
        #expect(report.isComplete && report.canProceed)
        // A scripted report is answered verbatim: a blocked host is what the wizard has to show.
        let blocked = PreflightCheck.run(snapshot: HostProbeSnapshot(), now: Date(timeIntervalSince1970: 0))
        await backend.setHostPreflight(blocked)
        #expect(try await collect(backend.send(.hostPreflight)) == [.hostPreflight(blocked)])
        #expect(!blocked.canProceed)
        // A query, like the version and status queries: no operation identity is invented.
        #expect(await backend.receivedRequests == [.hostPreflight, .hostPreflight])
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

    @Test func aCanceledOperationStaysInFlightUntilItsOwnTerminalEvent() async throws {
        let backend = FakeRuntimeBackend(), acknowledgment = OperationID()
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        var target = backend.send(.startEnvironment(environment, StartOptions())).makeAsyncIterator()
        try #require(try await target.next() == .accepted(operation))
        // The scripted post-cancellation status still names the operation, as a runtime's would
        // while the target winds down: the acknowledgment must not rewrite it.
        let winding = EnvironmentStatus(environmentID: environment, vm: .running, readiness: .checking,
                                        inFlightOperation: operation)
        await backend.useOperationID(acknowledgment, forNext: "cancelOperation")
        await backend.script("cancelOperation", .succeed(status: winding))
        #expect(try await collect(backend.send(.cancelOperation(operation))) == [.completed(acknowledgment)])
        // Whatever a query sees between the acknowledgment and the terminal event, it is one
        // of two settled shapes — never a status that dropped the operation before it ended.
        let observed = await backend.status(of: environment)
        #expect(observed == winding || observed?.inFlightOperation == nil)
        #expect(try await target.next() == .failed(operation, .canceled))
        #expect(await backend.status(of: environment)?.inFlightOperation == nil, "the target's own terminal event is what clears it")
    }

    @Test func aRefusedCancellationFailsAsItsOwnRequestNotAsTheTarget() async throws {
        let backend = FakeRuntimeBackend(), refusal = OperationID()
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        var target = backend.send(.startEnvironment(environment, StartOptions())).makeAsyncIterator()
        try #require(try await target.next() == .accepted(operation))
        await backend.useOperationID(refusal, forNext: "cancelOperation")
        await backend.script("cancelOperation", .fail(error: .invalidRequest(.unsupportedOperation)))
        #expect(try await collect(backend.send(.cancelOperation(operation))) == [.failed(refusal, .invalidRequest(.unsupportedOperation))])
        await backend.script("cancelOperation", .disconnect())
        // No operation of its own, but a mutation that may have gone out: the production
        // router keeps the target as the cancellation target, not as this failure's operation.
        await #expect(throws: RuntimeSessionFailure(cause: .connectionLost, mayHaveMutated: true)) {
            try await collect(backend.send(.cancelOperation(operation)))
        }
        #expect(await backend.status(of: environment)?.inFlightOperation == operation, "the target is untouched by a cancellation that failed")
    }

    private func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
