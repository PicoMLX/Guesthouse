import GuesthouseCore
import Testing
@testable import GuesthouseClientKit

struct RuntimeBackendFactoryTests {
    @Test(arguments: [
        [:], ["XCODE_RUNNING_FOR_PREVIEWS": "1"], ["GUESTHOUSE_FAKE_RUNTIME": "0"],
        ["GUESTHOUSE_FAKE_RUNTIME": "1"], ["XCTestConfigurationFilePath": "fixture"],
        ["GUESTHOUSE_FAKE_RUNTIME": "1", "XCTestConfigurationFilePath": "fixture", "XCODE_RUNNING_FOR_PREVIEWS": "1"]
    ])
    func launchEnvironmentCannotSelectSimulationInProduction(environment: [String: String]) {
        let backend = RuntimeBackendFactory.makeBackend(environment: environment)
        #if DEBUG
        let simulated = environment["GUESTHOUSE_FAKE_RUNTIME"] == "1" || environment["XCTestConfigurationFilePath"] != nil
        #expect(simulated ? backend is FakeRuntimeBackend : backend is RuntimeClient)
        #else
        #expect(backend is RuntimeClient)
        #expect(!(backend is FakeRuntimeBackend))
        #endif
    }
}
