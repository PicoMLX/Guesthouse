import Foundation
import GuesthouseCore
import SwiftUI

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
        /// Carried to the rendered button, so deleting a development Mac is never styled like
        /// a routine fix (MVP-PLAN.md §2).
        var buttonRole: ButtonRole? { isDestructive ? .destructive : nil }
    }

    let title: String
    let message: String
    let options: [Option]
    /// True when the last operation's result is not established: retry is never offered.
    let outcomeUnknown: Bool

    /// - Parameters:
    ///   - retryAvailable: whether the model holds a request it could replay. A problem the
    ///     runtime reported on its own (no operation this window started) has nothing to
    ///     retry, so the option says so instead of doing nothing.
    ///   - retryBlockedReason: why replaying that request would be refused right now, such as
    ///     another development Mac running.
    ///   - dismissAvailable: false for a problem the status keeps reporting: dismissing the
    ///     local error would leave the identical panel in place, so the option explains that
    ///     instead of appearing to do nothing.
    init(error: GuesthouseError, retryAvailable: Bool = true, retryBlockedReason: String? = nil, dismissAvailable: Bool = true) {
        let unknown: Bool = if case .operationOutcomeUnknown = error { true } else { false }
        title = unknown ? "Checking environment" : "Needs attention"
        message = error.userMessage
        outcomeUnknown = unknown
        options = error.recoveryActions.map {
            Self.option(for: $0, outcomeUnknown: unknown, retryAvailable: retryAvailable, retryBlockedReason: retryBlockedReason, dismissAvailable: dismissAvailable)
        }
    }

    /// The distinct state after a lost connection: the runtime is asked again before anything
    /// else is offered, and there is no Retry and nothing to dismiss (MVP-PLAN.md §3).
    init(unknownOutcomeOf operation: OperationID) {
        let error = GuesthouseError.operationOutcomeUnknown(operation)
        title = "Checking environment"
        message = error.userMessage + " Guesthouse is asking the runtime what actually happened before offering anything else."
        outcomeUnknown = true
        options = [Self.option(for: .inspectState, outcomeUnknown: true)]
    }

    static func option(for action: RecoveryAction, outcomeUnknown: Bool, retryAvailable: Bool = true, retryBlockedReason: String? = nil, dismissAvailable: Bool = true) -> Option {
        switch action {
        case .retry:
            Option(action: action, title: "Try again", availability: Self.retryAvailability(outcomeUnknown: outcomeUnknown, retryAvailable: retryAvailable, blockedReason: retryBlockedReason))
        case .inspectState:
            Option(action: action, title: "Check environment", availability: .enabled)
        case .cancel:
            Option(action: action, title: "Dismiss", availability: dismissAvailable
                   ? .enabled
                   : .disabled(reason: "The runtime still reports this, so dismissing it would change nothing. It clears when the development Mac reports otherwise."))
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

    private static func retryAvailability(outcomeUnknown: Bool, retryAvailable: Bool, blockedReason: String?) -> EnvironmentCardState.Availability {
        if outcomeUnknown {
            return .disabled(reason: "The result of the last operation is not known yet. Check the environment first.")
        }
        if let blockedReason {
            return .disabled(reason: blockedReason)
        }
        return retryAvailable ? .enabled : .disabled(reason: "Nothing to try again from here: the runtime reported this on its own. Use Start when it is offered, or check the environment.")
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
        /// The phase cannot be interrupted, so the runtime records the request and stops at
        /// the next step that can be; Cancel says so before taking it.
        case deferred(reason: String)
        /// Nothing can be canceled yet: the runtime has not accepted the operation, so there
        /// is no id to cancel by.
        case unavailable(reason: String)
    }

    let title: String
    let fraction: Double?
    let cancelability: Cancelability

    init(phase: ProgressPhase?, request: RuntimeRequest, accepted: Bool = true) {
        title = phase.map(EnvironmentCardState.describe) ?? Self.describe(request)
        fraction = phase?.fraction
        if !accepted {
            cancelability = .unavailable(reason: "Waiting for the runtime to accept the operation.")
        } else if let phase, !phase.cancelable {
            // `EnvironmentLifecycle.cancel` never interrupts a protected phase: it records the
            // request and honors it at the next step that can be interrupted, and an operation
            // with no such step left finishes normally. The dialog says exactly that.
            cancelability = .deferred(reason: "\"\(title)\" cannot be interrupted. Guesthouse will stop at the next step that can be; if there is none, the operation finishes on its own.")
        } else {
            cancelability = .immediate
        }
    }

    /// An operation the runtime reports but this window did not start: its phase is not
    /// known, only that it runs, and it can be canceled by the reported id.
    init(recoveredOperation: OperationID) {
        title = "Operation in progress…"
        fraction = nil
        cancelability = .immediate
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
