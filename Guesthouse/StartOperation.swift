import GuesthouseCore

/// One explicitly requested Start. No retry, provider command or cached readiness authority.
@MainActor enum StartOperation {
    enum Failure: Error, Equatable {
        case check(AppModel.CheckState), runtime(GuesthouseError), interrupted(RuntimeSessionFailure)
        case quitPending, stateChanged, notRunning
        var message: String {
            switch self {
            case .check(let state): QuitCoordinator.Failure.check(state).userMessage + " " + QuitCoordinator.Failure.check(state).recoveryMessage
            case .runtime(let error): error.userMessage + " " + error.recoveryMessage
            case .interrupted(let error): error.userMessage + " " + (error.recoverySuggestion ?? "Inspect the environment before continuing.")
            case .quitPending: "Start was not sent because Guesthouse is quitting. Cancel Quit to continue working."
            case .notRunning: "Start completed, but Guesthouse could not confirm that the development Mac is running. Inspect its current state before trying again."
            case .stateChanged: "The environment is no longer eligible to start. Inspect its current state before continuing."
            }
        }
        var recoveryActions: [RecoveryAction] {
            switch self {
            case .check(let state): QuitCoordinator.Failure.check(state).recoveryActions
            case .runtime(let error): error.recoveryActions
            case .interrupted(let error): error.recoveryActions
            case .quitPending: [.cancel]
            case .stateChanged, .notRunning: [.inspectState, .cancel]
            }
        }
    }
    static func run(_ environment: EnvironmentID, backend: any RuntimeBackend,
                    accepted onAcceptance: (OperationID) -> Void, progress: (ProgressPhase) -> Void, diagnostic: (DiagnosticEvent) -> Void) async -> (failure: Failure?, mayHaveMutated: Bool) {
        var accepted: OperationID?, terminal = false, receivedEvent = false
        var failure: GuesthouseError?
        func malformed() -> Failure {
            .interrupted(.init(cause: .malformedResponse, operationID: accepted, mayHaveMutated: true))
        }
        do {
            for try await event in backend.send(.startEnvironment(environment, StartOptions())) {
                receivedEvent = true
                guard !terminal else { throw malformed() }
                switch event {
                case .accepted(let id):
                    guard accepted == nil else { throw malformed() }; accepted = id; onAcceptance(id)
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
            return (failure.map(Failure.runtime), accepted != nil || isUnknown(failure))
        } catch let error as Failure { return (error, true) }
        catch let error as RuntimeSessionFailure { return (.interrupted(error.contextualized(operationID: accepted, mayHaveMutated: true)), true) }
        catch let error as GuesthouseError {
            // Only a local admission rejection before any event proves non-admission.
            // Stream cancellation and errors after a reply cannot erase uncertainty.
            return (.runtime(error), receivedEvent || accepted != nil || Task.isCancelled || error == .canceled || isUnknown(error))
        }
        catch { return (malformed(), true) }
    }
    private static func isUnknown(_ error: GuesthouseError?) -> Bool {
        if case .operationOutcomeUnknown = error { return true }
        return false
    }
    /// Cancellation has its own reply identity. Never use it as the target's terminal result.
    static func cancel(_ operation: OperationID, backend: any RuntimeBackend) async -> (failure: Failure?, retryAllowed: Bool) {
        var answered = false
        var failure: GuesthouseError?
        do {
            for try await event in backend.send(.cancelOperation(operation)) {
                guard !answered else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
                switch event {
                case .completed: answered = true
                case .failed(_, let error): answered = true; failure = error
                default: throw GuesthouseError.invalidRuntimeReply(.malformed)
                }
            }
            guard answered else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
            let retryAllowed: Bool
            switch failure {
            // Only an explicit admission refusal proves this cancellation did not run.
            // Canceled/unknown/transport-like failures require inspection, not another request.
            case .invalidRequest?: retryAllowed = true
            default: retryAllowed = false
            }
            return (failure.map(Failure.runtime), retryAllowed)
        } catch let error as RuntimeSessionFailure { return (.interrupted(error.contextualized(mayHaveMutated: true)), false) }
        catch let error as GuesthouseError {
            // RuntimeClient can reject locally before sending by throwing, rather than
            // yielding a terminal event. A throw after any reply cannot prove non-admission.
            if !answered, case .invalidRequest = error { return (.runtime(error), true) }
            return (.runtime(error), false)
        }
        catch { return (.runtime(.invalidRuntimeReply(.malformed)), false) }
    }

}
