import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeInstanceTests {
    @Test(arguments: [EnvironmentStatus.VMState.running, .stopped, .notFound, .uncertain(reason: .ownershipUnproven)])
    func onlyRunningStatusCanCarryInstance(vm: EnvironmentStatus.VMState) throws {
        let token = UUID()
        let status = EnvironmentStatus(environmentID: EnvironmentID(), vm: vm, readiness: .ready, runtimeInstanceID: token)
        let expected = vm == .running ? token : nil
        #expect(status.runtimeInstanceID == expected)
        #expect(try RuntimeEventEnvelope.decode(RuntimeEventEnvelope(event: .status(status)).encoded()).event == .status(status))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        object["runtimeInstanceID"] = token.uuidString
        #expect(try JSONDecoder().decode(EnvironmentStatus.self, from: JSONSerialization.data(withJSONObject: object)).runtimeInstanceID == expected)
        object.removeValue(forKey: "runtimeInstanceID")
        #expect(try JSONDecoder().decode(EnvironmentStatus.self, from: JSONSerialization.data(withJSONObject: object)).runtimeInstanceID == nil)
    }

    @Test func forceRequiresAnExplicitInstanceOnWire() throws {
        let token = UUID(), environment = EnvironmentID()
        let request = RuntimeRequest.stopEnvironment(environment, .force(expectedInstanceID: token))
        let bytes = try JSONEncoder().encode(RuntimeRequestEnvelope(request: request))
        #expect(try RequestValidator.decode(bytes).request == request)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(StopMode.self, from: Data(#"{"force":{}}"#.utf8)) }
    }

    @Test func fakeOperationBookkeepingPreservesInstanceWithoutInventingOne() async throws {
        let fake = FakeRuntimeBackend(), environment = EnvironmentID(), token = UUID()
        await fake.setStatus(.init(environmentID: environment, vm: .running, readiness: .ready, runtimeInstanceID: token))
        await fake.script("stopEnvironment", .fail(error: .guestShutdownRefused(environment)))
        for try await _ in fake.send(.stopEnvironment(environment, .graceful(deadline: .seconds(60)))) {}
        for try await event in fake.send(.environmentStatus(environment)) {
            guard case .status(let value) = event else { Issue.record("Expected status"); continue }
            #expect(value.runtimeInstanceID == token && value.inFlightOperation == nil)
        }
    }
}
