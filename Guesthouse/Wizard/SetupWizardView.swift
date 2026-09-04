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
                // The stage's own content scrolls and the footer below does not. Verbose
                // failure details, a row's recovery buttons and the storage summary together
                // exceed 520 points on a smaller display or at an accessibility text size, and
                // a plain stack would clip whatever did not fit — the recovery controls and
                // the navigation both. Setup has to stay actionable (MVP-PLAN.md §2).
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(wizard.current.title).font(.title2).bold()
                            .accessibilityAddTraits(.isHeader)
                        if wizard.current == .checkThisMac {
                            CheckThisMacView(model: wizard.checkThisMac)
                        } else {
                            Text("This step is not implemented yet. It arrives with a later change; the wizard resumes here when it does.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Scrolls for the same reason the stage content does: eight steps at an accessibility
    /// text size are taller than the sheet, and a clipped list hides the later steps.
    private var stageList: some View {
        ScrollView {
            stageRows
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 240)
        .background(.quaternary.opacity(0.3))
    }

    private var stageRows: some View {
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
        }
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
            if let progress = model.progressMessage {
                ProgressView(progress).accessibilityLabel(progress)
            }
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: row.verdict)).foregroundStyle(color(for: row.verdict))
                        Text(row.title).bold()
                        // A check's detail names a path: where Codex desktop was found, or the
                        // folder that could not be written. MVP-PLAN.md §2 "Essential screens"
                        // asks for paths the user can select and copy.
                        Text(row.detail).foregroundStyle(.secondary).textSelection(.enabled)
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
            // The note explains a recovery that was offered by the report on screen. A new
            // check replaces that report, so the note is cleared here exactly as it is when a
            // recovery button starts one: otherwise a note about "Open Settings" outlives the
            // failing row that offered it and sits under a report that now passes.
            Button("Check again") { note = nil; model.check() }
                .disabled(model.isChecking)
                .accessibilityLabel("Check this Mac again")
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
// Above the floor (the guest's 16 GiB allocation plus 8 GiB of host headroom) and below the
// recommendation, so this preview shows the warning state it is named for rather than the
// blocking memory failure 16 GiB produces.
#Preview("Warnings") { SetupWizardView(wizard: previewWizard(PreviewHostProbe(physicalMemoryBytes: 28 * ResourcePreset.gibibyte, powerSource: .battery, applications: [:]))) }
#Preview("Failure") { SetupWizardView(wizard: previewWizard(PreviewHostProbe(cpuArchitecture: .intel, freeBytesValue: 20 * ResourcePreset.gigabyte))) }
