import SwiftUI
import GuesthouseClientKit

struct StorageSetupView: View {
    let canPrepare: Bool
    @State private var setup: Task<Void, Never>?
    @State private var attempted = false
    @State private var outcome: RuntimeStorageSetup.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prepare Guesthouse’s storage folders for this account. Existing development Macs and saved work are kept.")
                .foregroundStyle(.secondary)
            Button("Prepare storage") {
                guard !attempted else { return }
                attempted = true
                setup = Task {
                    outcome = await RuntimeStorageSetup.run()
                    setup = nil
                }
            }
            .disabled(attempted || !canPrepare)
            .accessibilityIdentifier("prepareStorage")
            if !canPrepare && !attempted {
                Text("Check the runtime connection above before preparing storage.").foregroundStyle(.secondary)
            }
            if setup != nil { ProgressView("Preparing storage") }
            if let outcome {
                switch outcome {
                case .success:
                    Text("Storage is prepared. Run Check this Mac again before continuing.")
                case .failure(let error):
                    Text(error.userMessage)
                    Text(error.recoveryMessage).foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .onDisappear { setup?.cancel() } // Stops waiting; it does not undo an admitted setup.
    }
}
