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
                        let lume = info.lume.map(Self.describe) ?? "not located"
                        text = "Service \(info.serviceVersion) (\(info.serviceBuild)), \(info.protocolVersion), Lume: \(lume)"
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

    static func describe(_ lume: RuntimeVersionInfo.LumeRuntimeInfo) -> String {
        if lume.version == nil, lume.capabilities == nil, lume.problem == nil {
            return "checking"
        }
        let vncStatus = lume.capabilities.map {
            $0.vncCanBeDisabled ? "available" : "unavailable"
        } ?? "not checked"
        return "\(lume.version ?? "unknown version")\(lume.verified ? " verified" : " unverified"), VNC disable \(vncStatus)\(lume.problem.map { " (\($0.userMessage))" } ?? "")"
    }
}
