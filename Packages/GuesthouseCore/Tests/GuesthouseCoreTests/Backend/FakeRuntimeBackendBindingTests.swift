import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct FakeRuntimeBackendBindingTests {
    func acceptedID(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> OperationID? {
        var accepted: OperationID?
        for try await event in stream {
            if case .accepted(let id) = event { accepted = id }
        }
        return accepted
    }

    @Test func seededIDsBindToTheSendThatFollowsThem() async throws {
        let backend = FakeRuntimeBackend()
        let first = OperationID()
        let second = OperationID()
        await backend.useOperationID(first, forNext: "startEnvironment")
        let one = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        await backend.useOperationID(second, forNext: "startEnvironment")
        let two = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let three = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        #expect(try await acceptedID(one) == first)
        #expect(try await acceptedID(two) == second)
        let unseeded = try await acceptedID(three)
        #expect(unseeded != nil && unseeded != first && unseeded != second)
    }

    @Test func scriptChangesAfterSendDoNotAffectTheSentRequest() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("startEnvironment", .fail(error: .canceled))
        let stream = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        await backend.script("startEnvironment", .succeed())
        var names: [String] = []
        for try await event in stream { names.append(event.caseName) }
        #expect(names == ["accepted", "failed"])
    }

    @Test func cancellationClearsTheSeededInFlightOperationAndAppliesAScriptedStatus() async throws {
        let backend = FakeRuntimeBackend()
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: id))
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        let stream = backend.send(.startEnvironment(environment, StartOptions()))
        let consumer = Task { for try await _ in stream {} }
        while await backend.receivedRequests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        for try await _ in backend.send(.cancelOperation(id)) {}
        try await consumer.value
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
        let other = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready, inFlightOperation: other))
        await backend.script("cancelOperation", .succeed(status: EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready)))
        for try await _ in backend.send(.cancelOperation(other)) {}
        #expect(await backend.status(of: environment)?.vm == .stopped)
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test func aScriptedFailureClearsTheSeededInFlightOperation() async throws {
        let backend = FakeRuntimeBackend()
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: id))
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment)))
        for try await _ in backend.send(.startEnvironment(environment, StartOptions())) {}
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test func concurrentSendsKeepTheirSeededIDs() async throws {
        let backend = FakeRuntimeBackend()
        let ids = (0..<8).map { _ in OperationID() }
        var accepted: [OperationID?] = []
        for id in ids {
            await backend.useOperationID(id, forNext: "startEnvironment")
            accepted.append(try await acceptedID(backend.send(.startEnvironment(EnvironmentID(), StartOptions()))))
        }
        #expect(accepted == ids.map { Optional($0) })
    }

    @Test func aCompletedOperationIsNoLongerInFlightWithoutAScriptedStatus() async throws {
        let backend = FakeRuntimeBackend()
        let environment = EnvironmentID()
        let operation = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: operation))
        await backend.useOperationID(operation, forNext: "startEnvironment")
        for try await _ in backend.send(.startEnvironment(environment, StartOptions())) {}
        #expect(await backend.status(of: environment)?.inFlightOperation == nil, "a completed operation is not still in flight")
    }

    @Test func aConsumerCancelledDuringAProgressPhaseClearsTheInFlightOperation() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(30))
        let environment = EnvironmentID()
        let operation = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: operation))
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .succeed(phases: [ProgressPhase(kind: .startingVM), ProgressPhase(kind: .waitingForNetwork)]))
        let consumer = Task { for try await _ in backend.send(.startEnvironment(environment, StartOptions())) { break } }
        _ = try? await consumer.value
        for _ in 0..<200 where await backend.status(of: environment)?.inFlightOperation != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await backend.status(of: environment)?.inFlightOperation == nil, "a cancelled operation is not still in flight")
    }

    @Test func anOperationCancelledDuringItsTerminalPauseReportsCancellation() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(60))
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: id))
        await backend.useOperationID(id, forNext: "startEnvironment")
        let stream = backend.send(.startEnvironment(environment, StartOptions()))
        let collector = Task { try await acceptedID(stream) }
        try await Task.sleep(for: .milliseconds(30))
        for try await _ in backend.send(.cancelOperation(id)) {}
        _ = try? await collector.value
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test func aFailedCancellationRequestReleasesItsReservation() async throws {
        let backend = FakeRuntimeBackend()
        let id = OperationID()
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        await backend.script("cancelOperation", .fail(error: .invalidRequest(.unsupportedOperation)))
        let stream = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let consumer = Task { for try await _ in stream {} }
        while await backend.receivedRequests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        for try await _ in backend.send(.cancelOperation(id)) {}
        consumer.cancel()
        _ = try? await consumer.value
        for _ in 0..<200 where await backend.receivedRequests.filter({ $0 == .cancelOperation(id) }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancels = await backend.receivedRequests.filter { $0 == .cancelOperation(id) }
        #expect(cancels.count == 2, "the failed request did not suppress the consumer's own cancellation")
    }

    @Test func anAcceptedOperationIsInFlightForItsEnvironment() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(30))
        let environment = EnvironmentID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready))
        let stream = backend.send(.stopEnvironment(environment, .force))
        var iterator = stream.makeAsyncIterator()
        guard case .accepted(let id) = try await iterator.next() else { Issue.record("no accepted"); return }
        #expect(await backend.status(of: environment)?.inFlightOperation == id, "an accepted operation is in flight even when no caller seeded its id")
        #expect(try await iterator.next() == .completed(id))
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test func aScriptedStatusLeavesTheOperationInFlightUntilItCompletes() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(30))
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: id))
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready)))
        let stream = backend.send(.startEnvironment(environment, StartOptions()))
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted(id))
        guard case .status = try await iterator.next() else { Issue.record("no status"); return }
        #expect(await backend.status(of: environment)?.vm == .running)
        #expect(await backend.status(of: environment)?.inFlightOperation == id, "the operation is still in flight until its own terminal event")
        #expect(try await iterator.next() == .completed(id))
        #expect(await backend.status(of: environment)?.inFlightOperation == nil)
    }

    @Test func aConsumerCancelledBeforeAScriptedDisconnectionEndsAsCancelled() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(30))
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: id))
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .disconnect())
        let consumer = Task { for try await _ in backend.send(.startEnvironment(environment, StartOptions())) { break } }
        _ = try? await consumer.value
        for _ in 0..<200 where await backend.receivedRequests.filter({ $0 == .cancelOperation(id) }).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await backend.receivedRequests.contains(.cancelOperation(id)), "the cancellation before a scripted disconnection was not recorded")
        #expect(await backend.status(of: environment)?.inFlightOperation == nil, "a cancelled operation is not left in flight by a scripted disconnection")
    }

    @Test func aConsumerCancellationSuppressedByAReservationIsRecordedWhenThatRequestFails() async throws {
        let backend = FakeRuntimeBackend()
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready, inFlightOperation: id))
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        await backend.script("cancelOperation", .hang)
        let stream = backend.send(.startEnvironment(environment, StartOptions()))
        let consumer = Task { for try await _ in stream {} }
        while await backend.receivedRequests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        // The request reserves the id in `send` and then hangs, so the consumer's own
        // cancellation arrives while that reservation still stands.
        let cancelStream = backend.send(.cancelOperation(id))
        let canceller = Task { for try await _ in cancelStream {} }
        while await backend.receivedRequests.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        consumer.cancel()
        for _ in 0..<400 where await backend.status(of: environment)?.inFlightOperation != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await backend.status(of: environment)?.inFlightOperation == nil, "the consumer's cancellation ended the operation")
        canceller.cancel()
        _ = try? await canceller.value
        for _ in 0..<400 where await backend.receivedRequests.filter({ $0 == .cancelOperation(id) }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancels = await backend.receivedRequests.filter { $0 == .cancelOperation(id) }
        #expect(cancels.count == 2, "a request that never took effect swallowed the consumer's own cancellation")
    }

    @Test func explicitCancellationIsRecordedOnceEvenWhenTheConsumerAlsoStops() async throws {
        let backend = FakeRuntimeBackend()
        let id = OperationID()
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        let stream = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let consumer = Task {
            var names: [String] = []
            for try await event in stream { names.append(event.caseName) }
            return names
        }
        while await backend.receivedRequests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        for try await _ in backend.send(.cancelOperation(id)) {}
        consumer.cancel()
        _ = try? await consumer.value
        let cancels = await backend.receivedRequests.filter { $0 == .cancelOperation(id) }
        #expect(cancels.count == 1)
    }
}
