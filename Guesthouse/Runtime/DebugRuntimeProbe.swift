import Foundation
import GuesthouseCore
import Observation

/// Debug-only: exercises the `runtimeVersion` operation against the real service so the
/// XPC arrangement can be checked outside tests (issue #19). Not part of the product UI.
@Observable
final class DebugRuntimeProbe {
    var result: String = "Not requested"
    private let backend: any RuntimeBackend

    init(backend: any RuntimeBackend = RuntimeClient()) {
        self.backend = backend
    }

    func requestRuntimeVersion() {
        result = "Requesting…"
        Task {
            do {
                var text = "No reply"
                for try await event in backend.send(.runtimeVersion) {
                    if case .runtimeVersion(let info) = event {
                        text = "Service \(info.serviceVersion) (\(info.serviceBuild)), \(info.protocolVersion), Tart: \(info.tart.map { "\($0.version ?? "unknown version")\($0.verified ? " verified" : " unverified")\($0.problem.map { " (\($0.userMessage))" } ?? "")" } ?? "not located")"
                    } else {
                        text = "Unexpected reply: \(event.caseName)"
                    }
                }
                result = text
            } catch {
                result = "Connection interrupted: \(error)"
            }
        }
    }
}
