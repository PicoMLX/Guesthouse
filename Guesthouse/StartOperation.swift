import GuesthouseCore

/// One explicitly requested Start. No retry, provider command or cached readiness authority.
@MainActor enum StartOperation {
    enum Failure: Error, Equatable {
        case check(AppModel.CheckState), runtime(GuesthouseError), interrupted(RuntimeSessionFailure)
        case inspectionAfterStart(AppModel.CheckState)
        case quitPending, stateChanged, notRunning
        var message: String {
            switch self {
            case .check(let state): QuitCoordinator.Failure.check(state).userMessage + " " + QuitCoordinator.Failure.check(state).recoveryMessage
            case .inspectionAfterStart(let state): "Start may have completed. " + QuitCoordinator.Failure.check(state).userMessage + " Inspect its current state before continuing."
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
            case .inspectionAfterStart: [.inspectState, .cancel]
            case .runtime(let error): error.recoveryActions
            case .interrupted(let error): error.recoveryActions
            case .quitPending: [.cancel]
            case .stateChanged, .notRunning: [.inspectState, .cancel]
            }
        }
    }
    static func run(_ environment: EnvironmentID, backend: any RuntimeBackend,
                    accepted onAcceptance: (OperationID) -> Void, progress: (ProgressPhase) -> Void,
                    diagnostic: (DiagnosticEvent) -> Void, observation: (DiagnosticEvent.Outcome) -> Void) async -> (failure: Failure?, mayHaveMutated: Bool) {
        var accepted: OperationID?, terminal = false, receivedEvent = false
        var failure: GuesthouseError?
        func malformed() -> Failure {
            .interrupted(.init(cause: .malformedResponse, operationID: accepted, mayHaveMutated: true))
        }
        func retainUnknownOutcome() {
            if let accepted {
                diagnostic(DiagnosticEvent(operation: .startEnvironment, outcome: .operationFailed(.operationOutcomeUnknown(accepted)),
                    operationID: accepted.uuid, environmentID: environment))
            } else {
                // The app owns this dispatch observation; there is no accepted runtime ID.
                observation(.failed(.outcomeUnknown))
            }
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
                          DiagnosticIdentity.matches(event, environment: environment) else { throw malformed() }
                    diagnostic(event)
                case .completed(let id):
                    guard id == accepted else { throw malformed() }; terminal = true
                case .failed(let id, let error):
                    guard accepted == nil || accepted == id else { throw malformed() }
                    if case .guestShutdownRefused = error { throw malformed() }
                    let event = DiagnosticEvent(operation: .startEnvironment, outcome: .init(error: error),
                        operationID: id.uuid, environmentID: environment)
                    guard DiagnosticIdentity.matches(event, environment: environment) else { throw malformed() }
                    // Retain the terminal fact even when no intermediate diagnostic arrived.
                    // A later inspection failure must not replace the operation's own error.
                    diagnostic(event)
                    failure = error; terminal = true
                default: throw malformed()
                }
            }
            guard terminal else { throw malformed() }
            return (failure.map(Failure.runtime), accepted != nil || isUnknown(failure))
        } catch let error as Failure { retainUnknownOutcome(); return (error, true) }
        catch let error as RuntimeSessionFailure {
            retainUnknownOutcome()
            return (.interrupted(error.contextualized(operationID: accepted, mayHaveMutated: true)), true)
        }
        catch let error as GuesthouseError {
            // Only a local admission rejection before any event proves non-admission.
            // Stream cancellation and errors after a reply cannot erase uncertainty.
            let knownUnsent = !receivedEvent && accepted == nil && !Task.isCancelled && isLocalAdmissionRefusal(error)
            let mayHaveMutated = !knownUnsent
            if mayHaveMutated { retainUnknownOutcome() }
            else { observation(.operationFailed(error)) }
            return (.runtime(error), mayHaveMutated)
        }
        catch { retainUnknownOutcome(); return (malformed(), true) }
    }
    private static func isLocalAdmissionRefusal(_ error: GuesthouseError) -> Bool {
        if case .invalidRequest = error { return true }
        return false
    }
    private static func isUnknown(_ error: GuesthouseError?) -> Bool {
        if case .operationOutcomeUnknown = error { return true }
        return false
    }
    /// Cancellation has its own reply identity. Never use it as the target's terminal result.
    static func cancel(_ operation: OperationID, backend: any RuntimeBackend, environment: EnvironmentID? = nil,
                       diagnostic: (DiagnosticEvent) -> Void = { _ in },
                       observation: (DiagnosticEvent.Outcome) -> Void = { _ in }) async -> (failure: Failure?, retryAllowed: Bool) {
        var answered = false
        var replyID: OperationID?
        var failure: GuesthouseError?
        func retainUnknownOutcome() {
            if let replyID {
                diagnostic(DiagnosticEvent(operation: .cancelOperation, outcome: .operationFailed(.operationOutcomeUnknown(replyID)),
                    operationID: replyID.uuid, environmentID: environment))
            } else { observation(.failed(.outcomeUnknown)) }
        }
        do {
            for try await event in backend.send(.cancelOperation(operation)) {
                guard !answered else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
                switch event {
                case .completed(let id):
                    guard id != operation else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
                    replyID = id; answered = true
                    // This acknowledges only the cancellation request, never its target.
                    diagnostic(DiagnosticEvent(operation: .cancelOperation, outcome: .cancellationRequested,
                        operationID: id.uuid, environmentID: environment))
                case .failed(let id, let error):
                    guard id != operation else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
                    if case .guestShutdownRefused = error { throw GuesthouseError.invalidRuntimeReply(.malformed) }
                    let retained = DiagnosticEvent(operation: .cancelOperation, outcome: .operationFailed(error),
                        operationID: id.uuid, environmentID: environment)
                    guard DiagnosticIdentity.matches(retained, environment: environment) else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
                    replyID = id; answered = true; failure = error
                    diagnostic(retained)
                default: throw GuesthouseError.invalidRuntimeReply(.malformed)
                }
            }
            guard answered else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
            let retryAllowed: Bool
            switch failure {
            // Only an explicit admission refusal proves this cancellation did not run.
            case .invalidRequest?: retryAllowed = true
            default: retryAllowed = false
            }
            return (failure.map(Failure.runtime), retryAllowed)
        } catch let error as RuntimeSessionFailure {
            retainUnknownOutcome()
            return (.interrupted(error.contextualized(mayHaveMutated: true)), false)
        }
        catch let error as GuesthouseError {
            // A thrown local refusal before any reply is not runtime admission.
            if !answered, !Task.isCancelled, case .invalidRequest = error {
                observation(.operationFailed(error)); return (.runtime(error), true)
            }
            retainUnknownOutcome(); return (.runtime(error), false)
        }
        catch { retainUnknownOutcome(); return (.runtime(.invalidRuntimeReply(.malformed)), false) }
    }

}
