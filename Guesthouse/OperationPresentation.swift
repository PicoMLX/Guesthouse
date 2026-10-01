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
    let message: String
    let actions: [RecoveryAction]
    let outcomeUnknown: Bool
    init(error: GuesthouseError) {
        message = error.userMessage
        if case .operationOutcomeUnknown = error { outcomeUnknown = true } else { outcomeUnknown = false }
        actions = outcomeUnknown ? error.recoveryActions.filter { $0 != .retry } : error.recoveryActions
    }
    init(failure: StartOperation.Failure) {
        message = failure.message
        switch failure {
        case .interrupted(let value): outcomeUnknown = value.outcomeUnknown
        case .runtime(.operationOutcomeUnknown): outcomeUnknown = true
        default: outcomeUnknown = false
        }
        actions = outcomeUnknown ? failure.recoveryActions.filter { $0 != .retry } : failure.recoveryActions
    }
}
