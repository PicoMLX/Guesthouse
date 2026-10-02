import Foundation
import GuesthouseCore

/// Temporary response interpretation only. Help advertises options; it proves no VM,
/// VNC containment, Stop, GPU, provider selection or executable verification capability.
enum LumeProbeResponse: Equatable, Sendable {
    case version(SemanticVersion)
    case createHelp(unattendedTahoeAdvertised: Bool, storageAdvertised: Bool)
    case detachedRunHelp(detachAdvertised: Bool, storageAdvertised: Bool)
    case attachHelp(nativeDisplayAdvertised: Bool, storageAdvertised: Bool)

    static func parse(_ bytes: Data, command: LumeLaunchIntent.Command) throws -> Self {
        guard bytes.count <= 1 << 20, !bytes.contains(0),
              let text = String(data: bytes, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LumeProbeResponseFailure.invalidResponse
        }
        if command == .version {
            guard bytes.count <= SemanticVersion.maximumInputLength,
                  let version = SemanticVersion(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw LumeProbeResponseFailure.invalidResponse
            }
            // Compatibility equality normalizes components; executable identity does not.
            guard text.trimmingCharacters(in: .whitespacesAndNewlines) == LumePin.version.description else {
                throw LumeProbeResponseFailure.versionMismatch
            }
            return .version(version)
        }
        let tokens = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init))
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let storage = tokens.contains("--storage")
        switch command {
        case .createHelp: return .createHelp(unattendedTahoeAdvertised: tokens.contains("--unattended") && words.contains("tahoe"), storageAdvertised: storage)
        case .detachedRunHelp: return .detachedRunHelp(detachAdvertised: tokens.contains("--detach"), storageAdvertised: storage)
        case .attachHelp: return .attachHelp(nativeDisplayAdvertised: tokens.contains("--display") && words.contains("native"), storageAdvertised: storage)
        case .version: throw LumeProbeResponseFailure.invalidResponse
        }
    }

    static func checked(_ report: ProcessReport, output: OutputReaders.Response?,
                        command: LumeLaunchIntent.Command) throws -> Self {
        // Refused termination/unknown exit takes precedence over a generic timeout.
        guard !report.terminationRefused else { throw LumeProbeResponseFailure.interrupted }
        guard !report.canceled, !Task.isCancelled else { throw LumeProbeResponseFailure.interrupted }
        guard !report.timedOut else { throw LumeProbeResponseFailure.timedOut }
        guard let exit = report.childExit, case .success(let reason) = exit else {
            throw LumeProbeResponseFailure.interrupted
        }
        guard reason == .status(0) else {
            let status: Int32
            switch reason { case .status(let value): status = value; case .signal(let value): status = 128 + value }
            throw LumeProbeResponseFailure.processFailed(status: status)
        }
        guard report.inputClosed, report.outputComplete, let output, output.isComplete else {
            throw LumeProbeResponseFailure.invalidResponse
        }
        return try parse(output.stdout, command: command)
    }
}

/// Closed errors never retain output, executable paths or arbitrary error descriptions.
enum LumeProbeResponseFailure: Error, Equatable, Sendable, LocalizedError {
    case interrupted, timedOut, processFailed(status: Int32), invalidResponse, versionMismatch
    var userMessage: String {
        switch self {
        case .interrupted: "The runtime inspection has an unknown outcome. Preserve its storage and inspect the owned processes before continuing."
        case .timedOut: "The runtime inspection exceeded its time limit. Inspect its actual outcome before another launch."
        case .processFailed: "The runtime inspection returned a failure. Inspect the retained launch before continuing."
        case .invalidResponse: "The runtime inspection did not return a complete supported response. Inspect the retained launch before continuing."
        case .versionMismatch: "The runtime inspection returned a version that does not exactly match Guesthouse's pin. Preserve the installation and inspect it in Repair."
        }
    }
    var recoveryActions: [RecoveryAction] { [.inspectState, .cancel] }
    var errorDescription: String? { userMessage }
    var diagnosticOutcome: DiagnosticEvent.Outcome {
        switch self {
        case .interrupted: .failed(.outcomeUnknown)
        case .timedOut: .failed(.timedOut)
        case .processFailed(let status): .failed(.processFailed, exitStatus: status)
        case .invalidResponse: .failed(.invalidResponse)
        case .versionMismatch: .failed(.verificationFailed)
        }
    }
}
