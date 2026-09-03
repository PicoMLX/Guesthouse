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
