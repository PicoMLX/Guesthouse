import SwiftUI
import GuesthouseCore

/// Named phase, determinate where possible, and a Cancel that asks first when the phase must
/// not be interrupted.
struct OperationProgressView: View {
    let presentation: OperationProgressPresentation
    let cancel: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let fraction = presentation.fraction {
                    ProgressView(value: fraction).accessibilityLabel("Progress \(Int(fraction * 100)) percent")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("In progress")
                }
                Button("Cancel") {
                    switch presentation.cancelability {
                    case .immediate: cancel()
                    case .deferred: confirming = true
                    case .unavailable: break
                    }
                }
                .accessibilityLabel("Cancel operation")
                .disabled({ if case .unavailable = presentation.cancelability { true } else { false } }())
                .help({ if case .unavailable(let reason) = presentation.cancelability { reason } else { "" } }())
            }
            Text(presentation.title).font(.callout).foregroundStyle(.secondary)
        }
        // Nothing is interrupted here, so the choice is not destructive and does not claim to
        // stop anything now: the runtime stops at the next step it may stop at.
        .confirmationDialog("Cancel at the next step?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Cancel when possible") { cancel() }
            Button("Keep going", role: .cancel) {}
        } message: {
            if case .deferred(let reason) = presentation.cancelability { Text(reason) }
        }
    }
}

/// The message and one button per recovery action; unimplemented actions say so when tapped.
struct ErrorRecoveryView: View {
    let presentation: RecoveryPresentation
    let perform: (RecoveryAction) -> Void
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(presentation.title, systemImage: presentation.outcomeUnknown ? "questionmark.circle" : "exclamationmark.triangle")
                .font(.headline)
            Text(presentation.message).font(.callout)
            // An error's options are as many and as long as the error makes them; four of
            // them do not fit one line of a card at the grid's narrow column.
            WrappingHStack(spacing: 8, lineSpacing: 8) {
                ForEach(presentation.options) { option in
                    AvailabilityButton(option.title, availability: option.availability, role: option.buttonRole) { choose(option) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(option.title)
                }
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).accessibilityLabel("Note: \(note)")
            }
        }
        // One failure replaced directly by another keeps this view's position, and with it a
        // note describing an option that belonged to the failure that is gone.
        .onChange(of: presentation) { note = nil }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
    }

    private func choose(_ option: RecoveryPresentation.Option) {
        switch option.availability {
        case .enabled:
            note = nil
            perform(option.action)
        case .disabled(let reason):
            note = reason
        case .notImplemented(let text):
            note = "\(option.title) is not implemented yet. \(text)"
        }
    }
}

/// A collapsible, read-only, copyable view of the redacted log for the current operation.
struct LogDisclosureView: View {
    let lines: [RedactedLine]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { entry in
                        Text(entry.element.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        } label: {
            Text("Log (\(lines.count) \(lines.count == 1 ? "line" : "lines"))").font(.callout)
        }
        .accessibilityLabel("Operation log, \(lines.count) lines")
    }
}

// MARK: - Previews

#Preview("Progress") {
    ScenarioPreview { await PreviewScenarios.operationInProgress() }
}

#Preview("Failure") {
    ScenarioPreview { await PreviewScenarios.environmentNeedingRepair() }
}

#Preview("Unknown outcome") {
    ScenarioPreview {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        var slots = VMSlotInventory()
        try? slots.reserve(environment.id)
        let backend = FakeRuntimeBackend()
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .disconnect())
        await backend.script("environmentStatus", .disconnect())
        return PreviewScenario(name: "Unknown outcome", snapshot: EnvironmentsSnapshot(environments: [environment], slots: slots), backend: backend, initialRequest: .startEnvironment(environment.id, StartOptions()))
    }
}
