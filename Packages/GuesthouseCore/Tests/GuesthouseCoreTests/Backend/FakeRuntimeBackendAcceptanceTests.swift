import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct FakeRuntimeBackendAcceptanceTests {
    enum Mutation: Sendable {
        case start, stop, importXcode

        func request(for environment: EnvironmentID) -> RuntimeRequest {
            switch self {
            case .start: .startEnvironment(environment, StartOptions())
            case .stop: .stopEnvironment(environment, .force)
            case .importXcode:
                .importXcode(environment, FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app"))
            }
        }
    }

    @Test(arguments: [Mutation.start, .stop, .importXcode])
    func acceptedOperationsAreVisibleWithoutASeededStatus(_ mutation: Mutation) async throws {
        let backend = FakeRuntimeBackend()
        let environment = EnvironmentID()
        let operation = OperationID()
        let request = mutation.request(for: environment)
        await backend.script(request.caseName, .hang)
        await backend.useOperationID(operation, forNext: request.caseName)

        let stream = backend.send(request)
        var iterator = stream.makeAsyncIterator()
        try #require(try await iterator.next() == .accepted(operation))

        let inFlight = EnvironmentStatus(
            environmentID: environment, vm: .uncertain(reason: "No status has been observed."), readiness: .checking,
            inFlightOperation: operation
        )
        #expect(await backend.status(of: environment) == inFlight)
        var query = backend.send(.environmentStatus(environment)).makeAsyncIterator()
        #expect(try await query.next() == .status(inFlight))
        #expect(try await query.next() == nil)

        for try await _ in backend.send(.cancelOperation(operation)) {}
        #expect(try await iterator.next() == .failed(operation, .canceled))
        #expect(try await iterator.next() == nil)
        #expect(await backend.status(of: environment) == EnvironmentStatus(
            environmentID: environment, vm: .uncertain(reason: "No status has been observed."), readiness: .checking
        ))
    }
}
