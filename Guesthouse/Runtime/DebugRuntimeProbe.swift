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
                        text = Self.describe(info)
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

    static func describe(_ info: RuntimeVersionInfo) -> String {
        let tart = info.tart.map(Self.describe) ?? "not located"
        let lume = info.lume.map(Self.describe) ?? "not located"
        return "Service \(info.serviceVersion) (\(info.serviceBuild)), \(info.protocolVersion), Tart: \(tart), Lume: \(lume)"
    }

    static func describe(_ tart: RuntimeVersionInfo.TartRuntimeInfo) -> String {
        "\(tart.version)\(tart.verified ? " verified" : " unverified")"
    }

    static func describe(_ lume: RuntimeVersionInfo.LumeRuntimeInfo) -> String {
        if lume.version == nil, lume.capabilities == nil, lume.problem == nil {
            return "checking"
        }
        let vncStatus = lume.capabilities.map {
            $0.vncCanBeDisabled ? "available" : "unavailable"
        } ?? "not checked"
        let problem = lume.problem.map {
            let actions = $0.recoveryActions.map(Self.describe).joined(separator: "; ")
            let recovery = actions.isEmpty ? "" : " Declared recovery: \(actions)."
            return " (\($0.userMessage)\(recovery))"
        } ?? ""
        return "\(lume.version ?? "unknown version")\(lume.verified ? " verified" : " unverified"), VNC disable \(vncStatus)\(problem)"
    }

    private static func describe(_ action: RecoveryAction) -> String {
        switch action {
        case .retry: "Try again"
        case .inspectState: "Inspect state"
        case .repair(.sshPairing): "Repair SSH pairing"
        case .repair(.credentials): "Repair credentials"
        case .repair(.runtime): "Repair runtime"
        case .repair(.tools): "Repair tools"
        case .repair(.xcodeComponents): "Repair Xcode components"
        case .openConsole: "Open Mac console"
        case .exportWork: "Export work"
        case .openSettings: "Open Settings"
        case .signInAgain: "Sign in again"
        case .freeDiskSpace: "Free disk space"
        case .deleteEnvironment: "Delete environment"
        case .reinstallApp: "Reinstall Guesthouse"
        case .cancel: "Cancel"
        }
    }
}
