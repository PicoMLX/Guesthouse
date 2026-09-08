import Foundation

/// The only MVP diagnostic payload (ADR 0003). No arbitrary message, path, URL, arguments,
/// environment, stdout, stderr or underlying error can be attached to an event.
/// IDs must come from Guesthouse's operation/environment records, not guest output.
public struct DiagnosticEvent: Codable, Hashable, Sendable {
    public enum Operation: String, CaseIterable, Codable, Sendable {
        case preflight, verifyRuntime, createEnvironment, startEnvironment, stopEnvironment
        case inspectEnvironment, connectSSH, importXcode, checkTools, codexSignIn, githubSignIn
        case synchronizeRepositories, testWorkspace, publishChanges, exportDiagnostics
        case deleteEnvironment, exportWork, openConsole, repairEnvironment, updateGuest

        public var title: String {
            switch self {
            case .preflight: "Check this Mac"
            case .verifyRuntime: "Verify runtime"
            case .createEnvironment: "Create development Mac"
            case .startEnvironment: "Start development Mac"
            case .stopEnvironment: "Stop development Mac"
            case .inspectEnvironment: "Inspect development Mac"
            case .connectSSH: "Connect over SSH"
            case .importXcode: "Import Xcode"
            case .checkTools: "Check tools"
            case .codexSignIn: "Sign in to Codex"
            case .githubSignIn: "Sign in to GitHub"
            case .synchronizeRepositories: "Synchronize repositories"
            case .testWorkspace: "Test workspace"
            case .publishChanges: "Publish changes"
            case .exportDiagnostics: "Export diagnostics"
            case .deleteEnvironment: "Delete development Mac"
            case .exportWork: "Export work"
            case .openConsole: "Open development Mac console"
            case .repairEnvironment: "Repair development Mac"
            case .updateGuest: "Update development Mac"
            }
        }
    }

    public enum Outcome: Codable, Hashable, Sendable {
        case started, succeeded, cancellationRequested
        /// Emit only after cancellation/termination is confirmed, not when it is requested.
        case canceled
        case failed(DiagnosticFailure)
        case operationFailed(GuesthouseError)
    }

    public let operation: Operation
    public let outcome: Outcome
    public let operationID: UUID
    public let environmentID: EnvironmentID?
    public let exitStatus: Int32?

    public init(
        operation: Operation, outcome: Outcome, operationID: UUID,
        environmentID: EnvironmentID? = nil, exitStatus: Int32? = nil
    ) {
        self.operation = operation
        self.outcome = outcome
        self.operationID = operationID
        self.environmentID = environmentID
        self.exitStatus = exitStatus
    }

    /// Render locally from closed enums. Decoded/guest-supplied message text is never used.
    public var message: String {
        let detail: String
        switch outcome {
        case .started: detail = "Started."
        case .succeeded: detail = "Succeeded."
        case .cancellationRequested: detail = "Cancellation requested; completion is not yet confirmed."
        case .canceled: detail = "Cancellation confirmed; partial changes may remain."
        case .failed(let failure): detail = failure.message
        case .operationFailed(let error): detail = error.userMessage
        }
        return operation.title + ": " + detail
            + (exitStatus.map { " Exit status: \($0)." } ?? "")
    }

    public var recoveryMessage: String? {
        switch outcome {
        case .failed(let failure): recovery(for: failure)
        case .operationFailed(let error): error.recoveryMessage
        case .cancellationRequested: "Wait for the operation to stop, then inspect its outcome."
        case .canceled: "Inspect any partial changes before starting another operation."
        case .started, .succeeded: nil
        }
    }

    private func recovery(for failure: DiagnosticFailure) -> String {
        guard [.timedOut, .processFailed, .outcomeUnknown].contains(failure) else {
            return failure.recoveryMessage
        }
        switch operation {
        case .preflight:
            return "Run Check this Mac again and review the host requirements in Settings."
        case .verifyRuntime:
            return "Open Repair and inspect the runtime installation before trying again."
        case .exportDiagnostics:
            return "Check the selected export location and available disk space before exporting again."
        case .codexSignIn, .githubSignIn:
            return "Open Accounts and check sign-in status before trying again."
        case .exportWork:
            return "Inspect the export destination and the development Mac before trying again."
        case .synchronizeRepositories, .testWorkspace, .publishChanges:
            return "Inspect the workspace and any remote changes before trying the operation again."
        default:
            return failure.recoveryMessage
        }
    }
}
