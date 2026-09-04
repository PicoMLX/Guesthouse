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
                Text(model.quitConfirmationMessage)
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
                failure(title: "A development Mac did not stop", message: error.userMessage)
            case .checkFailed(let interruption):
                failure(title: "Guesthouse could not check what is running", message: interruption.userMessage)
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

    /// A failure the Quit sheet cannot get past on its own. What it offers next to Cancel is
    /// the failure's own recovery, so an error prescribing a repair or a reinstall is never
    /// answered with a check that only returns the same error (AGENTS.md: every error carries
    /// a user-facing message and at least one recovery action).
    @ViewBuilder
    private func failure(title: String, message: String) -> some View {
        Text(title).font(.headline)
        Text(message)
        switch model.quitRecovery {
        case .forceStop:
            Text("Force-stopping is like pulling the power: unsaved work inside the guest can be lost.").font(.callout).foregroundStyle(.red)
        case .check:
            Text("Guesthouse must check the development Mac's state before offering anything else.").font(.callout).foregroundStyle(.secondary)
        case .guidance(let guidance):
            Text(guidance).font(.callout).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
        HStack {
            Spacer()
            Button("Cancel") { model.cancelQuit() }.keyboardShortcut(.cancelAction).accessibilityLabel("Cancel quitting")
            switch model.quitRecovery {
            case .forceStop:
                Button("Force stop and quit", role: .destructive) { model.forceStopAndQuit() }.accessibilityLabel("Force stop and quit")
            case .check:
                Button("Check Environment") { model.inspectAndContinueQuit() }.keyboardShortcut(.defaultAction).accessibilityLabel("Check environment before quitting")
            case .guidance, nil:
                EmptyView()
            }
        }
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
