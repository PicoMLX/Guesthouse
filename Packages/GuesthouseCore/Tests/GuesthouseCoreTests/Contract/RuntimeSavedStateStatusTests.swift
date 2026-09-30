import Foundation
import Testing
@testable import GuesthouseCore

struct RuntimeSavedStateStatusTests {
    @Test(arguments: RuntimeSavedStateStatus.allCases)
    func optionalStatusSurvivesWireRoundTrip(status: RuntimeSavedStateStatus) throws {
        let value = RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "2", savedState: status)
        let bytes = try JSONEncoder().encode(RuntimeEvent.runtimeVersion(value))
        #expect(try JSONDecoder().decode(RuntimeEvent.self, from: bytes) == .runtimeVersion(value))
        #expect(!status.userMessage.isEmpty && !status.recoveryMessage.isEmpty)
    }

    @Test func olderVersionReplyDoesNotInventSuccessfulLoading() throws {
        let bytes = Data("{\"serviceVersion\":\"1\",\"serviceBuild\":\"2\",\"protocolVersion\":13}".utf8)
        #expect(try JSONDecoder().decode(RuntimeVersionInfo.self, from: bytes).savedState == nil)
    }
}
