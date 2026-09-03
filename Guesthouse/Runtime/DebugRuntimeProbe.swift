import Foundation
import GuesthouseCore
import Observation

/// Debug-only: exercises the `runtimeVersion` operation against the real service so the
/// XPC arrangement can be checked outside tests (issue #19). Not part of the product UI.
@Observable
final class DebugRuntimeProbe {
    /// Only the newest request may publish: a slower earlier probe never overwrites it.
    private var generation: UInt64 = 0
    private var probeTask: Task<Void, Never>?

    var result: String = "Not requested"
    private let backend: any RuntimeBackend

    init(backend: any RuntimeBackend) {
        self.backend = backend
    }

    /// Debug-only: pick an Xcode and ask the service to validate it through the handoff.
    func importXcodeCandidate() {
        // Every outcome of the picker replaces whatever was running, including the ones that
        // publish immediately: a scan still in flight must not overwrite the answer to the
        // command the user just gave.
        let generation = invalidatePreviousProbe()
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
        result = "Validating \(GuesthouseError.sanitize(handoff.displayName, limit: 120))…"
        probeTask = Task {
            do {
                var text = "No reply"
                for try await event in backend.send(.importXcode(EnvironmentID(), handoff)) {
                    switch event {
                    case .xcodeCandidate(let candidate):
                        text = Self.describe(candidate)
                    case .failed(_, let error):
                        text = "Rejected: \(error.userMessage)"
                    default:
                        text = "Unexpected reply: \(event.caseName)"
                    }
                }
                guard generation == self.generation else { return }
                result = text
            } catch {
                guard generation == self.generation else { return }
                result = "Connection interrupted: \(GuesthouseError.sanitize(String(describing: error), limit: 120))"
            }
        }
    }

    /// How a validated candidate reads.
    ///
    /// The estimate is clamped rather than converted: the service may legitimately report any
    /// `UInt64`, and `ByteCountFormatter` takes an `Int64`, so a bundle measured above
    /// `Int64.max` would trap and take the app down instead of being shown.
    static func describe(_ candidate: XcodeCandidate) -> String {
        let size = candidate.sizeEstimateBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "unknown size"
        return "Xcode \(candidate.version) (\(candidate.build)) at \(GuesthouseError.sanitize(candidate.path, limit: 200)), about \(size)"
    }

    /// Retires the request in flight and returns the generation of the new one.
    private func invalidatePreviousProbe() -> UInt64 {
        generation &+= 1
        probeTask?.cancel()
        probeTask = nil
        return generation
    }

    func requestRuntimeVersion() {
        result = "Requesting…"
        let generation = invalidatePreviousProbe()
        probeTask = Task {
            do {
                var text = "No reply"
                for try await event in backend.send(.runtimeVersion) {
                    if case .runtimeVersion(let info) = event {
                        text = "Service \(info.serviceVersion) (\(info.serviceBuild)), \(info.protocolVersion), Tart: \(info.tart.map { "\($0.version ?? "unknown version")\($0.verified ? " verified" : " unverified")\($0.problem.map { " (\($0.userMessage))" } ?? "")" } ?? "not located")"
                    } else {
                        text = "Unexpected reply: \(event.caseName)"
                    }
                }
                guard generation == self.generation else { return }
                result = text
            } catch {
                guard generation == self.generation else { return }
                result = "Connection interrupted: \(GuesthouseError.sanitize(String(describing: error), limit: 120))"
            }
        }
    }
}
