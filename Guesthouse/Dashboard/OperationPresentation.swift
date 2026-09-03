import Foundation
import GuesthouseCore

/// What the GUI shows for a failure: the message and one option per recovery action. Retry,
/// inspect, and cancel are wired; the other actions are present but visibly unimplemented
/// (MVP-PLAN.md §10: never "something went wrong" as the only recovery information).
struct RecoveryPresentation: Equatable {
    struct Option: Equatable, Identifiable {
        let action: RecoveryAction
        let title: String
        let availability: EnvironmentCardState.Availability
        var id: String { title }
        var isDestructive: Bool { action == .deleteEnvironment }
    }

    let title: String
    let message: String
    let options: [Option]
    /// True when the last operation's result is not established: retry is never offered.
    let outcomeUnknown: Bool

    init(error: GuesthouseError) {
        let unknown: Bool = if case .operationOutcomeUnknown = error { true } else { false }
        title = unknown ? "Checking environment" : "Needs attention"
        message = error.userMessage
        outcomeUnknown = unknown
        options = error.recoveryActions.map { Self.option(for: $0, outcomeUnknown: unknown) }
    }

    /// The distinct state after a lost connection: the runtime is asked again before anything
    /// else is offered, and there is no Retry (MVP-PLAN.md §3).
    init(unknownOutcomeOf operation: OperationID) {
        let error = GuesthouseError.operationOutcomeUnknown(operation)
        title = "Checking environment"
        message = error.userMessage + " Guesthouse is asking the runtime what actually happened before offering anything else."
        outcomeUnknown = true
        options = [.inspectState, .cancel].map { Self.option(for: $0, outcomeUnknown: true) }
    }

    static func option(for action: RecoveryAction, outcomeUnknown: Bool) -> Option {
        switch action {
        case .retry:
            Option(action: action, title: "Try again", availability: outcomeUnknown
                   ? .disabled(reason: "The result of the last operation is not known yet. Check the environment first.")
                   : .enabled)
        case .inspectState:
            Option(action: action, title: "Check environment", availability: .enabled)
        case .cancel:
            Option(action: action, title: "Dismiss", availability: .enabled)
        case .repair(let kind):
            Option(action: action, title: "Repair \(Self.name(of: kind))…", availability: .notImplemented(note: "Targeted repairs arrive with the repair flows (MVP-PLAN.md §9)."))
        case .openConsole:
            Option(action: action, title: "Open Mac console", availability: .notImplemented(note: "The Mac console arrives in Phase 2 (MVP-PLAN.md §10)."))
        case .exportWork:
            Option(action: action, title: "Export work…", availability: .notImplemented(note: "Work export arrives in Phase 3 (MVP-PLAN.md §10)."))
        case .openSettings:
            Option(action: action, title: "Open Settings", availability: .notImplemented(note: "Settings arrive with the setup wizard (#31)."))
        case .signInAgain:
            Option(action: action, title: "Sign in again", availability: .notImplemented(note: "Sign-in flows arrive in Phase 2 (MVP-PLAN.md §10)."))
        case .freeDiskSpace:
            Option(action: action, title: "Free disk space", availability: .notImplemented(note: "Storage guidance arrives with the setup wizard (#31)."))
        case .deleteEnvironment:
            Option(action: action, title: "Delete environment…", availability: .notImplemented(note: "Deletion arrives after work export exists (MVP-PLAN.md §2)."))
        case .reinstallApp:
            Option(action: action, title: "Reinstall Guesthouse", availability: .notImplemented(note: "Reinstall guidance arrives with the release process (MVP-PLAN.md §10)."))
        }
    }

    private static func name(of kind: RepairKind) -> String {
        switch kind {
        case .sshPairing: "SSH pairing"
        case .credentials: "credentials"
        case .runtime: "runtime"
        case .tools: "tools"
        case .xcodeComponents: "Xcode components"
        }
    }
}

/// What the GUI shows while an operation runs: the named phase, a fraction when the phase can
/// measure itself, and how Cancel behaves (MVP-PLAN.md §2 step 2: real phase progress, not one
/// indefinite spinner).
struct OperationProgressPresentation: Equatable {
    enum Cancelability: Equatable {
        case immediate
        /// The phase must not be interrupted casually; Cancel asks first.
        case confirmFirst(reason: String)
    }

    let title: String
    let fraction: Double?
    let cancelability: Cancelability

    init(phase: ProgressPhase?, request: RuntimeRequest) {
        title = phase.map(EnvironmentCardState.describe) ?? Self.describe(request)
        fraction = phase?.fraction
        if let phase, !phase.cancelable {
            cancelability = .confirmFirst(reason: "\"\(title)\" should not be interrupted. Canceling now can leave the development Mac needing repair.")
        } else {
            cancelability = .immediate
        }
    }

    private static func describe(_ request: RuntimeRequest) -> String {
        switch request {
        case .startEnvironment: "Starting the development Mac…"
        case .stopEnvironment: "Stopping the development Mac…"
        case .importXcode: "Importing Xcode…"
        default: "Working…"
        }
    }
}
