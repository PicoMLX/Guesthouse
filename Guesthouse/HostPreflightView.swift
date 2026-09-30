import SwiftUI
import GuesthouseClientKit
import GuesthouseCore

/// Read-only host observations; no setup/start action consumes this report as authority.
struct HostPreflightView: View {
    @State private var check: Task<Void, Never>?
    @State private var outcome: RuntimeHostPreflightQuery.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Check this Mac", action: startCheck)
                    .disabled(check != nil)
                    .accessibilityIdentifier("checkThisMac")
                if check != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking this Mac")
                    Button("Cancel", action: cancelCheck).disabled(check?.isCancelled == true)
                }
            }
            if let outcome {
                switch outcome {
                case .success(let report):
                    Text(report.canProceed ? "Host requirements checked." : "Some host requirements need attention.")
                        .font(.headline)
                    Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .standard)). Check again if this Mac changes.")
                        .foregroundStyle(.secondary)
                    ForEach(report.results, id: \.kind) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(result.userMessage, systemImage: result.isBlocking ? "exclamationmark.circle" : "info.circle")
                            if !result.recoveryActions.isEmpty {
                                Text(result.recoveryActions.map(\.title).joined(separator: "; ")).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(report.storage.locationDescription).foregroundStyle(.secondary)
                    Text("Provider, guest and Codex connection verification is still required before development can begin.")
                        .foregroundStyle(.secondary)
                case .failure(let error):
                    Text(error.userMessage)
                    Text(error.recoveryMessage).foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("hostPreflightResult")
        .onDisappear(perform: cancelCheck)
    }

    private func startCheck() {
        guard check == nil else { return }
        outcome = nil
        check = Task {
            let result = await RuntimeHostPreflightQuery.run()
            outcome = Task.isCancelled ? .failure(.canceled) : result
            check = nil
        }
    }

    private func cancelCheck() {
        guard let check else { return }
        check.cancel()
        outcome = .failure(.canceled)
        // Remain occupied until the query drains; a late reply cannot overwrite a later check.
    }
}
