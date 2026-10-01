import GuesthouseCore

/// Typed errors can carry IDs too. Check those before a consumer attributes or retains an event.
nonisolated enum DiagnosticIdentity {
    static func matches(_ event: DiagnosticEvent, environment: EnvironmentID?) -> Bool {
        guard event.isRuntimeEvent else { return false }
        guard event.environmentID == nil || event.environmentID == environment else { return false }
        guard case .operationFailed(let error) = event.outcome else { return true }
        switch error {
        case .guestNotReachable(let id), .hostKeyChanged(let id), .guestShutdownRefused(let id):
            return id == environment
        case .operationOutcomeUnknown(let id): return id.uuid == event.operationID
        default: return true
        }
    }
}
