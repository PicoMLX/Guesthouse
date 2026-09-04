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
    ///   - dismissBlockedReason: why the failure cannot be dismissed, when it cannot: a
    ///     problem the status keeps reporting would leave the identical panel in place, and
    ///     the check's own failure carries the card's only way to ask again. The option
    ///     explains that instead of appearing to do nothing.
    ///   - inspectionOffered: whether the failure is one another status check would answer.
    ///     Such a failure gets a Check of its own when nothing else it carries can be pressed,
    ///     so a panel is never left as a message with every control disabled.
    init(error: GuesthouseError, retryAvailable: Bool = true, retryBlockedReason: String? = nil, dismissBlockedReason: String? = nil, inspectionOffered: Bool = false) {
        let unknown: Bool = if case .operationOutcomeUnknown = error { true } else { false }
        title = unknown ? "Checking environment" : "Needs attention"
        message = error.userMessage
        outcomeUnknown = unknown
        let offered = error.recoveryActions.map {
            Self.option(for: $0, outcomeUnknown: unknown, retryAvailable: retryAvailable, retryBlockedReason: retryBlockedReason, dismissBlockedReason: dismissBlockedReason)
        }
        // Added only when nothing else would work: an error that already offers a working
        // Try again or Check must not grow a second button that does the same thing.
        options = if inspectionOffered, !offered.contains(where: { $0.availability == .enabled }) {
            [Self.option(for: .inspectState, outcomeUnknown: unknown)] + offered
        } else {
            offered
        }
    }

    /// The distinct state after a lost connection: the runtime is asked again before anything
    /// else is offered, and there is no Retry and nothing to dismiss (MVP-PLAN.md §3).
    ///
    /// - Parameter inspectionFailure: why the check that would settle the outcome did not
    ///   succeed, when it did not. The outcome stays unknown, so nothing that mutates is
    ///   offered; the failure's own message and its safe recovery are shown alongside the
    ///   check, rather than another bare Check button that explains nothing.
    init(unknownOutcomeOf operation: OperationID, inspectionFailure: GuesthouseError? = nil) {
        let error = GuesthouseError.operationOutcomeUnknown(operation)
        title = "Checking environment"
        message = if let inspectionFailure {
            error.userMessage + " The check that would settle it did not succeed: " + inspectionFailure.userMessage
        } else {
            error.userMessage + " Guesthouse is asking the runtime what actually happened before offering anything else."
        }
        outcomeUnknown = true
        // Retry would mutate over an unestablished outcome, and dismissing would hide it, so
        // neither is carried over from the inspection failure's own actions.
        let safe = (inspectionFailure?.recoveryActions ?? []).filter { $0 != .retry && $0 != .inspectState && $0 != .cancel }
        options = [Self.option(for: .inspectState, outcomeUnknown: true)]
            + safe.map { Self.option(for: $0, outcomeUnknown: true) }
    }

    static func option(for action: RecoveryAction, outcomeUnknown: Bool, retryAvailable: Bool = true, retryBlockedReason: String? = nil, dismissBlockedReason: String? = nil) -> Option {
        switch action {
        case .retry:
            Option(action: action, title: "Try again", availability: Self.retryAvailability(outcomeUnknown: outcomeUnknown, retryAvailable: retryAvailable, blockedReason: retryBlockedReason))
        case .inspectState:
            Option(action: action, title: "Check environment", availability: .enabled)
        case .cancel:
            Option(action: action, title: "Dismiss", availability: dismissBlockedReason.map { .disabled(reason: $0) } ?? .enabled)
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

    /// Said of an operation the runtime has accepted but reported no step for. Named so the
    /// dialog and the tests that assert it cannot drift apart.
    static let unreportedPhaseReason = "Guesthouse has not been told which step this operation is on yet. It will stop at the next step that can be interrupted; if there is none, the operation finishes on its own."

    init(phase: ProgressPhase?, request: RuntimeRequest, accepted: Bool = true) {
        title = phase.map(EnvironmentCardState.describe) ?? Self.describe(request)
        fraction = phase?.fraction
        if !accepted {
            cancelability = .unavailable(reason: "Waiting for the runtime to accept the operation.")
        } else if case .stopEnvironment = request {
            // Every phase the runtime reports for a stop is uninterruptible, so a Cancel here
            // could only look like it would stop the shutdown; the sheet says so instead.
            cancelability = .unavailable(reason: "A stop runs to its end: the development Mac is shutting down.")
        } else if let phase, !phase.cancelable {
            // `EnvironmentLifecycle.cancel` never interrupts a protected phase: it records the
            // request and honors it at the next step that can be interrupted, and an operation
            // with no such step left finishes normally. The dialog says exactly that.
            cancelability = .deferred(reason: "\"\(title)\" cannot be interrupted. Guesthouse will stop at the next step that can be; if there is none, the operation finishes on its own.")
        } else if phase == nil {
            // Accepted, but no step reported yet. `EnvironmentLifecycle.cancel` treats a
            // missing phase as deferred because the first phase of both start and stop is
            // protected, so presenting Cancel as immediate here would skip the confirmation
            // and promise something the runtime will not do.
            cancelability = .deferred(reason: Self.unreportedPhaseReason)
        } else {
            cancelability = .immediate
        }
    }

    /// An operation the runtime reports but this window is no longer streaming: its phase is
    /// not known, only that it runs, and it can be canceled by the reported id.
    ///
    /// `request` is what this app asked for, when it knows: a stop whose stream dropped is
    /// still the same stop after the status reconnects to it, and every phase of a stop is
    /// uninterruptible, so offering Cancel here could only cancel it before its first phase
    /// or record a request that is deferred to an end that never comes.
    init(recoveredOperation: OperationID, request: RuntimeRequest? = nil) {
        title = "Operation in progress…"
        fraction = nil
        if case .stopEnvironment? = request {
            // Every phase the runtime reports for a stop is uninterruptible, so Cancel here
            // could only look like it would stop a shutdown that is already under way.
            cancelability = .unavailable(reason: "A stop runs to its end: the development Mac is shutting down.")
        } else {
            // Which step it is on is exactly what a recovered operation does not carry, and
            // `EnvironmentLifecycle.cancel` defers a cancellation during a protected phase and
            // lets the operation finish normally. Promising an immediate stop would misdescribe
            // what Cancel does, so the conservative case is presented (MVP-PLAN.md §2).
            cancelability = .deferred(reason: "Guesthouse did not start this operation, so it cannot tell which step it is on. It will stop at the next step that can be interrupted; if there is none, the operation finishes on its own.")
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
