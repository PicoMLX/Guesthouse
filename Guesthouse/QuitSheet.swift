import SwiftUI
import GuesthouseCore

struct QuitSheet: View {
    let coordinator: QuitCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch coordinator.flow {
            case .idle, .confirming:
                Text("Quit Guesthouse?").font(.headline)
                Text("Guesthouse checks what is running and stops development Macs before quitting. Saved work stays on their disks.")
                Text(coordinator.warning).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    cancelButton
                    Button("Stop environments and quit") { coordinator.confirmStopAndQuit() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Stop environments and quit")
                }
            case .checking:
                Text("Checking environment…").font(.headline)
                ProgressView().accessibilityLabel("Checking environment before quitting")
                Text("Guesthouse needs current state before stopping anything or finishing Quit.").foregroundStyle(.secondary)
                HStack { Spacer(); cancelButton }
            case .stopping(_, let phase, let force):
                Text(force ? "Force-stopping…" : "Stopping development Mac…").font(.headline)
                ProgressView(value: phase?.fraction).accessibilityLabel(force ? "Force-stopping development Mac" : "Stopping development Mac")
                if coordinator.cancelRequested {
                    Text("Waiting for this shutdown step to finish. Guesthouse will stay open.").foregroundStyle(.secondary)
                }
                HStack { Spacer(); cancelButton.disabled(coordinator.cancelRequested) }
            case .failed(let failure):
                Text("Guesthouse could not finish quitting").font(.headline)
                Text(failure.message)
                Text(failure.recovery).foregroundStyle(.secondary)
                if coordinator.canForceStop {
                    Text("Force-stopping is like pulling the power: unsaved work inside the guest can be lost.").foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    cancelButton
                    if coordinator.canForceStop {
                        Button("Force stop and quit", role: .destructive) { coordinator.forceStopAndQuit() }
                            .accessibilityLabel("Force stop and quit; unsaved work may be lost")
                    } else if failure.canInspect {
                        Button("Check environment") { coordinator.inspectBeforeContinuing() }
                            .accessibilityLabel("Check environment before continuing Quit")
                    }
                }
            case .terminating: Text("Quitting…").font(.headline)
            }
        }
        .padding(24)
        .frame(minWidth: 440, maxWidth: 540)
    }

    private var cancelButton: some View {
        Button("Cancel") { coordinator.cancelQuit() }
            .keyboardShortcut(.cancelAction).accessibilityLabel("Cancel quitting")
    }
}

extension QuitCoordinator.Failure {
    var message: String {
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
    var recovery: String {
        switch self {
        case .check(.metadataUnavailable(let state)): state.recoveryMessage
        case .check(.unavailable(let error)), .stop(let error): error.recoveryMessage
        case .check(.interrupted(let cause)): RuntimeSessionFailure(cause: cause).recoverySuggestion ?? "Cancel and check the runtime connection."
        case .interrupted(let failure): failure.recoverySuggestion ?? "Inspect the environment before continuing."
        default: "Inspect the environment before stopping anything else, or cancel to stay in Guesthouse."
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
