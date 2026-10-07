import SwiftUI
import GuesthouseCore

struct EnvironmentCheckView: View {
    let model: AppModel, quit: QuitCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.environmentSummary).font(.headline)
                Spacer()
                if model.isChecking { ProgressView().controlSize(.small).accessibilityLabel("Checking environment") }
                Button("Check environment") { model.checkEnvironments() }
                    .disabled(model.isChecking || model.isStarting || quit.flow != .idle)
                    .accessibilityIdentifier("checkEnvironment")
            }
            if model.backend is FakeRuntimeBackend { Text("Preview runtime — no development Mac is controlled.").foregroundStyle(.secondary) }
            if !model.recoveredOperations.isEmpty {
                Text("A previously observed operation still needs inspection. Check the environment before starting or stopping anything. Missing saved records do not confirm that it stopped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch model.checkState {
            case .metadataUnavailable(let state): Text(state.recoveryMessage).foregroundStyle(.secondary)
            case .unavailable(let error): Text(error.recoveryMessage).foregroundStyle(.secondary)
            case .interrupted(let cause): Text(RuntimeSessionFailure(cause: cause).recoverySuggestion ?? "Check the environment again.").foregroundStyle(.secondary)
            case .checkingEnvironment: Text("Saved records and live status are checked before new work.").foregroundStyle(.secondary)
            case .checked: EmptyView()
            }
        }
        .textSelection(.enabled)
    }

}

extension AppModel {
    var environmentSummary: String {
        switch checkState {
        case .checkingEnvironment: "Checking environment…"
        case .metadataUnavailable(let state): state.userMessage
        case .unavailable(let error): error.userMessage
        case .interrupted: "Runtime connection lost — check environment"
        case .checked:
            if environments.isEmpty { "No saved development Macs" }
            else if statuses.values.contains(where: { if case .uncertain = $0.vm { true } else { false } }) {
                "Development Mac state needs inspection"
            } else { "\(environments.count) saved development Mac\(environments.count == 1 ? "" : "s")" }
        }
    }
}
