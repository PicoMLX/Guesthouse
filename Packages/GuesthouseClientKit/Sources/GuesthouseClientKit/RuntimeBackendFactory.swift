import Foundation
import GuesthouseCore

/// GUI-safe launch policy. Production builds always choose the native backend.
/// Constructing a backend does not send a request or grant VM mutation authority.
public enum RuntimeBackendFactory: Sendable {
    public static func makeBackend(environment: [String: String] = ProcessInfo.processInfo.environment) -> any RuntimeBackend {
        #if DEBUG
        if environment["XCTestConfigurationFilePath"] != nil || environment["GUESTHOUSE_FAKE_RUNTIME"] == "1" {
            return FakeRuntimeBackend()
        }
        #endif
        return RuntimeClient()
    }
}
