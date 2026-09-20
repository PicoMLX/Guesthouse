import Foundation
import Testing
@testable import GuesthouseCore

/// Retained #60 send-time bindings and seeded-status cleanup, without scheduler sleeps.
@Suite(.timeLimit(.minutes(1))) struct FakeRuntimeBackendBindingTests {
    @Test func seededIDsBindToTheSendThatFollowsThem() async throws {
        let backend = FakeRuntimeBackend(), first = OperationID(), second = OperationID()
        await backend.useOperationID(first, forNext: "startEnvironment")
        let one = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        await backend.useOperationID(second, forNext: "startEnvironment")
        let two = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        let three = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        #expect(try await acceptedID(one) == first)
        #expect(try await acceptedID(two) == second)
        let unseeded = try #require(try await acceptedID(three))
        #expect(unseeded != first && unseeded != second)
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

    @Test func multipleOutstandingSendsKeepTheirSeededIDsAndRequestOrder() async throws {
        let backend = FakeRuntimeBackend()
        let ids = (0..<8).map { _ in OperationID() }
        let requests = ids.map { _ in RuntimeRequest.startEnvironment(EnvironmentID(), StartOptions()) }
        var streams: [AsyncThrowingStream<RuntimeEvent, any Error>] = []
        for (id, request) in zip(ids, requests) {
            await backend.useOperationID(id, forNext: "startEnvironment")
            streams.append(backend.send(request))
        }
        // All sends precede consumption. Reverse consumption must not reverse bindings/logs.
        for (id, stream) in zip(ids, streams).reversed() {
            #expect(try await acceptedID(stream) == id)
        }
        #expect(await backend.receivedRequests == requests)
    }

    @Test func seededIDsAreScopedToTheirRequestCase() async throws {
        let backend = FakeRuntimeBackend(), start = OperationID(), stop = OperationID()
        await backend.useOperationID(start, forNext: "startEnvironment")
        await backend.useOperationID(stop, forNext: "stopEnvironment")
        let stopStream = backend.send(.stopEnvironment(EnvironmentID(), .force))
        let startStream = backend.send(.startEnvironment(EnvironmentID(), StartOptions()))
        #expect(try await acceptedID(startStream) == start)
        #expect(try await acceptedID(stopStream) == stop)
    }

    @Test func completionClearsASeededOperationWithoutAScriptedStatus() async throws {
        let backend = FakeRuntimeBackend(), environment = EnvironmentID(), operation = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready,
                                                  inFlightOperation: operation))
        await backend.useOperationID(operation, forNext: "startEnvironment")
        #expect(try await acceptedID(backend.send(.startEnvironment(environment, StartOptions()))) == operation)
        #expect(await backend.status(of: environment) ==
                EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready))
    }

    @Test func scriptedFailureClearsASeededOperationWithoutChangingOtherStatusFields() async throws {
        let backend = FakeRuntimeBackend(), environment = EnvironmentID(), operation = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready,
                                                  inFlightOperation: operation))
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment)))
        var events: [RuntimeEvent] = []
        for try await event in backend.send(.startEnvironment(environment, StartOptions())) { events.append(event) }
        #expect(events == [.accepted(operation), .failed(operation, .guestNotReachable(environment))])
        #expect(await backend.status(of: environment) ==
                EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready))
    }

    private func acceptedID(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> OperationID? {
        var accepted: OperationID?
        for try await event in stream {
            if case .accepted(let id) = event { accepted = id }
        }
        return accepted
    }
}
