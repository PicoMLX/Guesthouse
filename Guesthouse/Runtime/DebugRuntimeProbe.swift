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

    /// Debug-only: pick an Xcode and ask the service to validate it through the handoff.
    func importXcodeCandidate() {
        let handoff: FileHandoff
        switch XcodeSelection.chooseXcode() {
        case .canceled:
            result = "Xcode selection canceled"
            return
        case .bookmarkFailed(let reason):
            result = "The selection could not be handed off: \(reason). Record this for gate #34."
            return
        case .handoff(let made):
            handoff = made
        }
        result = "Validating \(handoff.displayName)…"
        Task {
            do {
                var text = "No reply"
                for try await event in backend.send(.importXcode(EnvironmentID(), handoff)) {
                    switch event {
                    case .xcodeCandidate(let candidate):
                        text = "Xcode \(candidate.version) (\(candidate.build)) at \(candidate.path), about \(candidate.sizeEstimateBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "unknown size")"
                    case .failed(_, let error):
                        text = "Rejected: \(error.userMessage)"
                    default:
                        text = "Unexpected reply: \(event.caseName)"
                    }
                }
                result = text
            } catch {
                result = "Connection interrupted: \(error)"
            }
        }
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
