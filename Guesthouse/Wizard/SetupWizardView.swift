import SwiftUI
import GuesthouseCore

/// The setup wizard: resumable stages, the "Check this Mac" step, and placeholders that say
/// what is not implemented yet (MVP-PLAN.md §2 "First launch", "Essential screens").
struct SetupWizardView: View {
    @Bindable var wizard: SetupWizardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            stageList
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(wizard.current.title).font(.title2).bold()
                    .accessibilityAddTraits(.isHeader)
                if wizard.current == .checkThisMac {
                    CheckThisMacView(model: wizard.checkThisMac)
                } else {
                    Text("This step is not implemented yet. It arrives with a later change; the wizard resumes here when it does.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityLabel("Close setup")
                    Spacer()
                    Button("Back") { wizard.back() }.disabled(!wizard.canGoBack).accessibilityLabel("Back")
                    Button("Next") { wizard.next() }.disabled(!wizard.canGoNext).keyboardShortcut(.defaultAction).accessibilityLabel("Next")
                }
            }
            .padding(20)
        }
        .frame(minWidth: 780, minHeight: 520)
        .task { wizard.presented() }
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(wizard.stages.enumerated()), id: \.element) { index, stage in
                HStack(spacing: 8) {
                    Image(systemName: stage == wizard.current ? "circle.fill" : "circle").imageScale(.small)
                    Text("\(index + 1). \(stage.title)")
                        .fontWeight(stage == wizard.current ? .semibold : .regular)
                        .foregroundStyle(stage.isImplemented ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1), \(stage.title)\(stage == wizard.current ? ", current" : "")\(stage.isImplemented ? "" : ", not implemented yet")")
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 240)
        .background(.quaternary.opacity(0.3))
    }
}

/// One row per check with pass, warn, or fail, the download and storage summary, a re-run
/// button, and recovery actions on failure.
struct CheckThisMacView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CheckThisMacModel
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.rows.isEmpty, model.isChecking {
                ProgressView("Checking this Mac…").accessibilityLabel("Checking this Mac")
            }
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: row.verdict)).foregroundStyle(color(for: row.verdict))
                        Text(row.title).bold()
                        Text(row.detail).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.title): \(name(for: row.verdict)). \(row.detail)")
                    if !row.recovery.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(row.recovery) { option in
                                AvailabilityButton(option.title, availability: option.availability) { choose(option) }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel(option.title)
                            }
                        }
                        .padding(.leading, 26)
                    }
                }
            }
            if !model.storageSummary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloads and storage").font(.headline)
                    ForEach(model.storageSummary, id: \.self) { line in Text(line).font(.callout) }
                }
                .padding(.top, 8)
                // The storage line names where the VM will live; MVP-PLAN.md §"Essential
                // screens" asks for selectable paths, so the user can copy it.
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).accessibilityLabel("Note: \(note)")
            }
            Button("Check again") { model.check() }
                .disabled(model.isChecking)
                .accessibilityLabel("Check this Mac again")
            Spacer()
        }
    }

    private func choose(_ option: RecoveryPresentation.Option) {
        switch option.availability {
        case .enabled:
            note = nil
            switch option.action {
            case .retry, .inspectState: model.check()
            case .cancel: dismiss()
            default: break
            }
        case .disabled(let reason):
            note = reason
        case .notImplemented(let text):
            note = "\(option.title) is not implemented yet. \(text)"
        }
    }

    private func symbol(for verdict: CheckThisMacModel.Row.Verdict) -> String {
        switch verdict {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .undetermined: "questionmark.circle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    private func color(for verdict: CheckThisMacModel.Row.Verdict) -> Color {
        switch verdict {
        case .pass: .green
        case .warn: .orange
        case .undetermined: .orange
        case .fail: .red
        }
    }

    private func name(for verdict: CheckThisMacModel.Row.Verdict) -> String {
        switch verdict {
        case .pass: "passed"
        case .warn: "warning"
        case .undetermined: "could not be checked"
        case .fail: "failed"
        }
    }
}

// MARK: - Previews

/// A probe with fixed answers, for previews.
struct PreviewHostProbe: HostProbe {
    var cpuArchitecture: CPUArchitecture = .appleSilicon
    var operatingSystemVersion = SemanticVersion([26, 5, 2])
    var operatingSystemBuild: String? = "25F84"
    var physicalMemoryBytes: UInt64 = 32 * ResourcePreset.gibibyte
    var powerSource: PowerSource = .externalPower
    var freeBytesValue: UInt64 = 500 * ResourcePreset.gigabyte
    var applications: [String: InstalledApplication] = ["com.openai.chat": InstalledApplication(url: URL(fileURLWithPath: "/Applications/ChatGPT.app"), version: "1.2.3", build: "456")]

    func freeBytes(at url: URL) throws -> UInt64 { freeBytesValue }
    func installedApplication(bundleIdentifier: String) -> InstalledApplication? { applications[bundleIdentifier] }
}

private func previewWizard(_ probe: PreviewHostProbe) -> SetupWizardModel {
    let defaults = UserDefaults(suiteName: "preview-\(UUID().uuidString)")!
    return SetupWizardModel(defaults: defaults, checkThisMac: CheckThisMacModel(probe: probe))
}

#Preview("All pass") { SetupWizardView(wizard: previewWizard(PreviewHostProbe())) }
#Preview("Warnings") { SetupWizardView(wizard: previewWizard(PreviewHostProbe(physicalMemoryBytes: 16 * ResourcePreset.gibibyte, powerSource: .battery, applications: [:]))) }
#Preview("Failure") { SetupWizardView(wizard: previewWizard(PreviewHostProbe(cpuArchitecture: .intel, freeBytesValue: 20 * ResourcePreset.gigabyte))) }
