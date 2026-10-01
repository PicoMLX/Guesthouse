import GuesthouseCore

extension QuitCoordinator.Failure {
    var userMessage: String {
        switch self {
        case .check(.metadataUnavailable(let state)): state.userMessage
        case .check(.unavailable(let error)), .stop(let error): error.userMessage
        case .check(.interrupted(let cause)): RuntimeSessionFailure(cause: cause).userMessage
        case .check: "Guesthouse has not completed a current environment check."
        case .ownership(_, let reason): reason.userMessage
        case .unsettled: "An environment operation still has an unknown outcome."
        case .interrupted(let failure): failure.userMessage
        case .stillRunning: "A development Mac is still running after the stop operation ended."
        }
    }
    var recoveryMessage: String {
        switch self {
        case .check(.metadataUnavailable(let state)): state.recoveryMessage
        case .check(.unavailable(let error)), .stop(let error): error.recoveryMessage
        case .check(.interrupted(let cause)): RuntimeSessionFailure(cause: cause).recoverySuggestion ?? "Cancel and check the runtime connection."
        case .interrupted(let failure): failure.recoverySuggestion ?? "Inspect the environment before continuing."
        default: "Inspect the environment before stopping anything else, or cancel to stay in Guesthouse."
        }
    }
    var recoveryActions: [RecoveryAction] {
        switch self {
        case .check(.metadataUnavailable(.incompatible)): [.updateApp, .cancel]
        case .check(.unavailable(let error)), .stop(let error): error.recoveryActions
        case .check(.interrupted(let cause)): RuntimeSessionFailure(cause: cause).recoveryActions
        case .interrupted(let failure): failure.recoveryActions
        case .ownership(_, let reason): reason.recoveryActions
        default: [.inspectState, .cancel]
        }
    }
    var canInspect: Bool {
        switch self {
        case .check(.metadataUnavailable(let state)): state == .loading || state == .unavailable
        case .check(.unavailable(let error)), .stop(let error): error.recoveryActions.contains(.inspectState) || error.recoveryActions.contains(.retry)
        case .check(.interrupted(let cause)): cause == .connectionLost
        default: true
        }
    }
}
