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

    /// The replay has to land where the cancellation happened. A reservation can be released
    /// long after the consumer went away, and a coordinator test reading `receivedRequests`
    /// would otherwise see the requests it sent in between ahead of a cancellation that
    /// preceded them.
    @Test func aSuppressedCancellationIsReplayedWhereItHappened() async throws {
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
        let cancelStream = backend.send(.cancelOperation(id))
        let canceller = Task { for try await _ in cancelStream {} }
        while await backend.receivedRequests.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        consumer.cancel()
        for _ in 0..<400 where await backend.status(of: environment)?.inFlightOperation != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Sent after the consumer went away, so it must stay behind that cancellation.
        for try await _ in backend.send(.environmentStatus(environment)) {}
        canceller.cancel()
        _ = try? await canceller.value
        for _ in 0..<400 where await backend.receivedRequests.filter({ $0 == .cancelOperation(id) }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await backend.receivedRequests
        let replay = requests.lastIndex(of: .cancelOperation(id))
        let query = requests.firstIndex(of: .environmentStatus(environment))
        #expect(requests.filter { $0 == .cancelOperation(id) }.count == 2)
        #expect(replay != nil && query != nil && replay! < query!, "\(requests)")
    }

    /// Two suppressed cancellations reserve two slots, so replaying them puts them back in the
    /// order they happened whatever order their reservations are released in. Keying them on the
    /// length of the log instead made the second replay land in front of the first.
    @Test func twoSuppressedCancellationsKeepTheOrderTheyHappenedIn() async throws {
        let backend = FakeRuntimeBackend()
        let first = EnvironmentID()
        let second = EnvironmentID()
        let one = OperationID()
        let two = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: first, vm: .running, readiness: .ready, inFlightOperation: one))
        await backend.setStatus(EnvironmentStatus(environmentID: second, vm: .running, readiness: .ready, inFlightOperation: two))
        await backend.script("startEnvironment", .hang)
        await backend.script("cancelOperation", .hang)

        await backend.useOperationID(one, forNext: "startEnvironment")
        let firstStream = backend.send(.startEnvironment(first, StartOptions()))
        let firstConsumer = Task { for try await _ in firstStream {} }
        while await backend.receivedRequests.count < 1 { try await Task.sleep(for: .milliseconds(2)) }
        await backend.useOperationID(two, forNext: "startEnvironment")
        let secondStream = backend.send(.startEnvironment(second, StartOptions()))
        let secondConsumer = Task { for try await _ in secondStream {} }
        while await backend.receivedRequests.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        let firstCancel = backend.send(.cancelOperation(one))
        let firstCanceller = Task { for try await _ in firstCancel {} }
        while await backend.receivedRequests.count < 3 { try await Task.sleep(for: .milliseconds(2)) }
        let secondCancel = backend.send(.cancelOperation(two))
        let secondCanceller = Task { for try await _ in secondCancel {} }
        while await backend.receivedRequests.count < 4 { try await Task.sleep(for: .milliseconds(2)) }

        // The consumer of `one` goes away first, so its cancellation happened first.
        firstConsumer.cancel()
        for _ in 0..<400 where await backend.status(of: first)?.inFlightOperation != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        secondConsumer.cancel()
        for _ in 0..<400 where await backend.status(of: second)?.inFlightOperation != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Released in the same order, which is the order that used to invert the replays.
        firstCanceller.cancel()
        _ = try? await firstCanceller.value
        for _ in 0..<400 where await backend.receivedRequests.filter({ $0 == .cancelOperation(one) }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        secondCanceller.cancel()
        _ = try? await secondCanceller.value
        for _ in 0..<400 where await backend.receivedRequests.filter({ $0 == .cancelOperation(two) }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let requests = await backend.receivedRequests
        #expect(requests.suffix(2) == [.cancelOperation(one), .cancelOperation(two)], "\(requests)")
    }

    @Test func theEmittedScriptedStatusNamesTheOperationStillInFlight() async throws {
        let backend = FakeRuntimeBackend()
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready, inFlightOperation: id))
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready)))
        var emitted: EnvironmentStatus?
        for try await event in backend.send(.startEnvironment(environment, StartOptions())) {
            if case .status(let status) = event { emitted = status }
        }
        #expect(emitted?.inFlightOperation == id, "a consumer applying the status event must not see an idle environment while the operation runs")
    }

    @Test func aScriptedPostCancellationStatusDoesNotRestoreTheCanceledOperation() async throws {
        let backend = FakeRuntimeBackend()
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready, inFlightOperation: id))
        await backend.script("cancelOperation", .succeed(status: EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready, inFlightOperation: id)))
        for try await _ in backend.send(.cancelOperation(id)) {}
        #expect(await backend.status(of: environment)?.inFlightOperation == nil, "a scripted status must not put the canceled operation back in flight")
    }

    @Test func releasingOneReservationLeavesAnOverlappingRequestSpeakingForTheConsumer() async throws {
        let backend = FakeRuntimeBackend()
        let environment = EnvironmentID()
        let id = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready, inFlightOperation: id))
        await backend.useOperationID(id, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        await backend.script("cancelOperation", .hang)
        let consumer = Task { for try await _ in backend.send(.startEnvironment(environment, StartOptions())) {} }
        while await backend.receivedRequests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        // The first request reserves the id and then hangs, so its reservation still stands
        // while the second one is sent, released, and the consumer goes away.
        let pending = backend.send(.cancelOperation(id))
        let canceller = Task { for try await _ in pending {} }
        while await backend.receivedRequests.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        await backend.script("cancelOperation", .disconnect())
        await #expect(throws: RuntimeConnectionInterrupted.self) {
            for try await _ in backend.send(.cancelOperation(id)) {}
        }
        consumer.cancel()
        for _ in 0..<400 where await backend.status(of: environment)?.inFlightOperation != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await backend.status(of: environment)?.inFlightOperation == nil, "the consumer's cancellation ended the operation")
        // A later ticket cannot be served until every earlier one has been, so a synthetic
        // cancellation taken before this query is recorded by the time it replies.
        for try await _ in backend.send(.environmentStatus(environment)) {}
        let cancels = await backend.receivedRequests.filter { $0 == .cancelOperation(id) }
        #expect(cancels.count == 2, "the released request spoke for a reservation another request still holds")
        canceller.cancel()
        _ = try? await canceller.value
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
