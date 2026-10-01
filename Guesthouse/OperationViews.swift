import SwiftUI
import GuesthouseCore

struct OperationProgressView: View {
    let phase: ProgressPhase?
    let cancellationRequested: Bool
    var cancel: (() -> Void)?
    @State private var confirmingCancel = false
    var body: some View {
        let presentation = OperationProgressPresentation(phase: phase)
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(presentation.title, value: phase?.fraction)
                .accessibilityLabel(presentation.title)
            if cancellationRequested { Text("Cancellation requested. Waiting for the operation’s actual outcome.") }
            Button("Cancel operation") {
                if presentation.requiresCancellationConfirmation { confirmingCancel = true }
                else { cancel?() }
            }
            .disabled(cancel == nil || cancellationRequested)
            .help(cancel == nil ? "Wait for the current state inspection." : "Request cancellation and wait for its outcome.")
        }
        .confirmationDialog("This step may need to finish before cancellation is safe.", isPresented: $confirmingCancel) {
            Button("Request cancellation") { cancel?() }
            Button("Keep waiting", role: .cancel) {}
        } message: { Text("Partial changes may remain. Guesthouse will inspect the outcome before another attempt.") }
    }
}

struct ErrorRecoveryView: View {
    let presentation: RecoveryPresentation
    let canRetry: Bool
    let perform: (RecoveryAction) -> Void
    @State private var unavailable: RecoveryAction?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.outcomeUnknown { Text("Operation outcome unknown — inspect environment").font(.headline) }
            Text(presentation.message)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            if let unavailable { Text("\(unavailable.title) is not available in this view yet.").font(.caption) }
        }.textSelection(.enabled)
    }
    private var actions: some View {
        ForEach(presentation.actions, id: \.self) { action in
            Button(action.title) {
                switch action {
                case .retry, .inspectState, .cancel: perform(action)
                default: unavailable = action
                }
            }
            .disabled(action == .retry && (!canRetry || presentation.outcomeUnknown))
            .accessibilityHint(action == .retry ? "Checks current state before a new attempt." : action.title)
        }
    }
}

struct DiagnosticDisclosureView: View {
    let log: DiagnosticLog
    var body: some View {
        DisclosureGroup("Operation diagnostics (\(log.records.count))") {
            if log.records.isEmpty { Text("No structured events reported.").foregroundStyle(.secondary) }
            if log.discardedCount > 0 { Text("\(log.discardedCount) older events omitted.").font(.caption) }
            ForEach(Array(log.records.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading) {
                    Text(record.event.message)
                    if let recovery = record.event.recoveryMessage { Text(recovery).foregroundStyle(.secondary) }
                }.font(.caption).textSelection(.enabled)
            }
        }
    }
}

#Preview("Measured progress") { OperationProgressView(phase: .init(kind: .waitingForNetwork, fraction: 0.4), cancellationRequested: false, cancel: {}).padding() }
#Preview("Protected phase") { OperationProgressView(phase: .init(kind: .startingVM, cancelable: false), cancellationRequested: false, cancel: {}).padding() }
#Preview("Failure") { ErrorRecoveryView(presentation: .init(error: .runtimeMissing), canRetry: false) { _ in }.padding() }
#Preview("Unknown outcome") { ErrorRecoveryView(presentation: .init(error: .operationOutcomeUnknown(OperationID())), canRetry: false) { _ in }.padding() }
