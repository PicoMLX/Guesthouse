import SwiftUI
import GuesthouseCore

/// "Stop environments and quit" or "Cancel"; a warned force-stop only after graceful stop fails,
/// and only when the app knows what it would be force-stopping.
struct QuitSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.quitFlow {
            case .idle, .confirming:
                Text("Quit Guesthouse?").font(.headline)
                Text(model.runningEnvironments.isEmpty
                     ? "No development Mac is running."
                     : "Quitting stops \(model.runningEnvironments.count == 1 ? "the running development Mac" : "all running development Macs") first.")
                Text(model.quitWarning).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelQuit() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Cancel quitting")
                    Button("Stop environments and quit") { model.confirmStopAndQuit() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Stop environments and quit")
                }
            case .checking:
                Text("Checking environment…").font(.headline)
                ProgressView().accessibilityLabel("Checking environment before quitting")
                Text("Guesthouse checks what is running before stopping anything.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Cancel") { model.cancelQuit() }.accessibilityLabel("Cancel quitting") }
            case .stopping(let id, let phase):
                Text("Stopping…").font(.headline)
                ProgressView()
                    .accessibilityLabel("Stopping development Macs")
                Text(describe(id, phase)).foregroundStyle(.secondary)
                if model.quitCancelRequested {
                    Text("This step cannot be interrupted. Guesthouse stays open once it ends.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelQuit() }
                        .disabled(model.quitCancelRequested)
                        .accessibilityLabel("Cancel quitting")
                }
            case .stopFailed(let error):
                Text("A development Mac did not stop").font(.headline)
                Text(error.userMessage)
                if model.canForceStop {
                    Text("Force-stopping is like pulling the power: unsaved work inside the guest can be lost.").font(.callout).foregroundStyle(.red)
                } else {
                    Text("Guesthouse must check the development Mac's state before offering anything else.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelQuit() }.keyboardShortcut(.cancelAction).accessibilityLabel("Cancel quitting")
                    if model.canForceStop {
                        Button("Force stop and quit", role: .destructive) { model.forceStopAndQuit() }.accessibilityLabel("Force stop and quit")
                    } else {
                        Button("Check Environment") { model.inspectAndContinueQuit() }.keyboardShortcut(.defaultAction).accessibilityLabel("Check environment before quitting")
                    }
                }
            case .forceStopping:
                Text("Force-stopping…").font(.headline)
                ProgressView().accessibilityLabel("Force-stopping development Macs")
                if model.quitCancelRequested {
                    Text("A force-stop cannot be interrupted. Guesthouse stays open once it ends.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelQuit() }
                        .disabled(model.quitCancelRequested)
                        .accessibilityLabel("Cancel quitting")
                }
            case .terminating:
                Text("Quitting…").font(.headline)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func describe(_ id: EnvironmentID?, _ phase: ProgressPhase?) -> String {
        let name = id.flatMap { id in model.environments.first { $0.id == id }?.name } ?? "development Mac"
        switch phase?.kind {
        case .stoppingVM?: return "Asking \(name) to shut down…"
        case .forceStoppingVM?: return "Force-stopping \(name)…"
        default: return "Stopping \(name)…"
        }
    }
}
