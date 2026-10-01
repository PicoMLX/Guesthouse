import GuesthouseCore

struct OperationProgressPresentation {
    let phase: ProgressPhase?
    var title: String {
        switch phase?.kind {
        case .inspectingState: "Inspecting the environment…"
        case .verifyingRuntime: "Verifying the runtime…"
        case .startingVM: "Starting the development Mac…"
        case .waitingForNetwork: "Waiting for the development Mac to answer…"
        case .stoppingVM: "Shutting down the development Mac…"
        case .forceStoppingVM: "Force-stopping the development Mac…"
        case .validatingSelection: "Validating the selection…"
        case .copying: "Copying…"
        case .verifyingCopy: "Verifying the copy…"
        case nil: "Waiting for the current operation…"
        }
    }
    var requiresCancellationConfirmation: Bool { phase?.cancelable != true }
}

struct RecoveryPresentation {
    static func missingEnvironmentGuidance(hasFailure: Bool, needsInspection: Bool) -> String? {
        guard hasFailure else { return nil }
        return needsInspection
            ? "Inspect this environment before continuing. If it cannot be located safely, its state remains unknown. Repair for a missing environment is not available in this version."
            : "Start did not begin. Inspect the current environments before continuing."
    }
    let message: String
    let actions: [RecoveryAction]
    let outcomeUnknown: Bool
    static func isImplemented(_ action: RecoveryAction) -> Bool {
        switch action { case .retry, .inspectState, .cancel: true; default: false }
    }
    func canPerform(_ action: RecoveryAction, canRetry: Bool, canInspect: Bool) -> Bool {
        guard actions.contains(action), Self.isImplemented(action) else { return false }
        switch action {
        case .retry: return canRetry && !outcomeUnknown
        case .inspectState: return canInspect
        default: return true
        }
    }
    init(error: GuesthouseError) {
        message = error.userMessage + " " + error.recoveryMessage
        if case .operationOutcomeUnknown = error { outcomeUnknown = true } else { outcomeUnknown = false }
        actions = outcomeUnknown ? error.recoveryActions.filter { $0 != .retry } : error.recoveryActions
    }
    init(failure: StartOperation.Failure) {
        message = failure.message
        switch failure {
        case .inspectionAfterStart: outcomeUnknown = true
        case .interrupted(let value): outcomeUnknown = value.outcomeUnknown
        case .runtime(.operationOutcomeUnknown): outcomeUnknown = true
        default: outcomeUnknown = false
        }
        actions = outcomeUnknown ? failure.recoveryActions.filter { $0 != .retry } : failure.recoveryActions
    }
}
