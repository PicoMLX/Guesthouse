/// Named service-to-GUI events (#9, MVP-PLAN.md §3). Private status is not a diagnostic.
public enum RuntimeEvent: Codable, Hashable, Sendable {
    case runtimeVersion(RuntimeVersionInfo)
    /// The service must journal/register the operation before acknowledging acceptance.
    case accepted(OperationID)
    case progress(OperationID, ProgressPhase)
    /// UUIDs are assigned by Guesthouse. No raw-output or arbitrary-message alternative exists.
    case diagnostic(DiagnosticEvent)
    case status(EnvironmentStatus)
    case completed(OperationID)
    case failed(OperationID, GuesthouseError)

    public var caseName: String {
        switch self {
        case .runtimeVersion: "runtimeVersion"
        case .accepted: "accepted"
        case .progress: "progress"
        case .diagnostic: "diagnostic"
        case .status: "status"
        case .completed: "completed"
        case .failed: "failed"
        }
    }

    /// Only this explicit case can enter DiagnosticLog. Consumers must not stringify other
    /// events or infer operation completion from diagnostic presentation alone.
    public var diagnosticEvent: DiagnosticEvent? {
        if case .diagnostic(let event) = self { event } else { nil }
    }
}
