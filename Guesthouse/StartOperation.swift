import GuesthouseCore

/// One explicitly requested Start. No retry, provider command or cached readiness authority.
@MainActor enum StartOperation {
    enum Failure: Error, Equatable {
        case check(AppModel.CheckState), runtime(GuesthouseError), interrupted(RuntimeSessionFailure)
        case quitPending, stateChanged
        var message: String {
            switch self {
            case .check(let state): QuitCoordinator.Failure.check(state).userMessage + " " + QuitCoordinator.Failure.check(state).recoveryMessage
            case .runtime(let error): error.userMessage + " " + error.recoveryMessage
            case .interrupted(let error): error.userMessage + " " + (error.recoverySuggestion ?? "Inspect the environment before continuing.")
            case .quitPending: "Start was not sent because Guesthouse is quitting. Cancel Quit to continue working."
            case .stateChanged: "The environment is no longer eligible to start. Inspect its current state before continuing."
            }
        }
        var recoveryActions: [RecoveryAction] {
            switch self {
            case .check(let state): QuitCoordinator.Failure.check(state).recoveryActions
            case .runtime(let error): error.recoveryActions
            case .interrupted(let error): error.recoveryActions
            case .quitPending: [.cancel]
            case .stateChanged: [.inspectState, .cancel]
            }
        }
    }
    static func run(_ environment: EnvironmentID, backend: any RuntimeBackend,
                    progress: (ProgressPhase) -> Void, diagnostic: (DiagnosticEvent) -> Void) async -> Failure? {
        var accepted: OperationID?, terminal = false
        var failure: GuesthouseError?
        func malformed() -> Failure {
            .interrupted(.init(cause: .malformedResponse, operationID: accepted, mayHaveMutated: true))
        }
        do {
            for try await event in backend.send(.startEnvironment(environment, StartOptions())) {
                guard !terminal else { throw malformed() }
                switch event {
                case .accepted(let id):
                    guard accepted == nil else { throw malformed() }; accepted = id
                case .progress(let id, let phase):
                    guard id == accepted else { throw malformed() }; progress(phase)
                case .status(let status):
                    guard accepted != nil, status.environmentID == environment,
                          status.inFlightOperation == nil || status.inFlightOperation == accepted else { throw malformed() }
                case .diagnostic(let event):
                    guard accepted != nil, event.operationID == accepted?.uuid,
                          event.environmentID == nil || event.environmentID == environment else { throw malformed() }
                    diagnostic(event)
                case .completed(let id):
                    guard id == accepted else { throw malformed() }; terminal = true
                case .failed(let id, let error):
                    guard accepted == nil || accepted == id else { throw malformed() }
                    if case .guestShutdownRefused = error { throw malformed() }
                    failure = error; terminal = true
                default: throw malformed()
                }
            }
            guard terminal else { throw malformed() }
            return failure.map(Failure.runtime)
        } catch let error as Failure { return error }
        catch let error as RuntimeSessionFailure { return .interrupted(error.contextualized(operationID: accepted, mayHaveMutated: true)) }
        catch let error as GuesthouseError { return .runtime(error) }
        catch { return malformed() }
    }
}
