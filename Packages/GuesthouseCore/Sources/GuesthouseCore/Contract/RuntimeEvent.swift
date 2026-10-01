/// Named service-to-GUI events (#9, MVP-PLAN.md §3). Private status is not a diagnostic.
public enum RuntimeEvent: Codable, Hashable, Sendable {
    case runtimeVersion(RuntimeVersionInfo)
    /// Terminal reply to its owning query, never an unsolicited operation event.
    case hostPreflight(PreflightReport)
    /// Owning list query reply only, never a readiness result or unsolicited push.
    case environments(RuntimeEnvironmentInventory)
    /// Terminal reply to its owning selection query, never an operation or unsolicited push.
    case xcodeSelection(XcodeSelectionResult)
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
        case .hostPreflight: "hostPreflight"
        case .environments: "environments"
        case .xcodeSelection: "xcodeSelection"
        case .accepted: "accepted"
        case .progress: "progress"
        case .diagnostic: "diagnostic"
        case .status: "status"
        case .completed: "completed"
        case .failed: "failed"
        }
    }

    /// Extract only an explicit diagnostic payload; never stringify other events. An owning
    /// operation may map a validated terminal GuesthouseError to a DiagnosticEvent. Diagnostic
    /// presentation alone never establishes operation completion or live environment state.
    public var diagnosticEvent: DiagnosticEvent? {
        if case .diagnostic(let event) = self { event } else { nil }
    }
}
