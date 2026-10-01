import Foundation
import SwiftUI
import Observation

nonisolated enum SetupStage: String, CaseIterable, Identifiable {
    case checkThisMac, createDevelopmentMac, finishMacOSSetup, connectSecurely, addXcode, signIn, addWorkspace, validateAndOpen
    var id: Self { self }
    var title: String {
        switch self {
        case .checkThisMac: "Check this Mac"
        case .createDevelopmentMac: "Create development Mac"
        case .finishMacOSSetup: "Finish macOS setup"
        case .connectSecurely: "Connect securely"
        case .addXcode: "Add Xcode"
        case .signIn: "Sign in"
        case .addWorkspace: "Add workspace"
        case .validateAndOpen: "Validate and open"
        }
    }
}

/// Persist navigation only. A saved stage is never completed work or runtime admission.
@MainActor @Observable final class SetupWizardModel {
    private(set) var stage: SetupStage
    let host: HostPreflightModel
    @ObservationIgnored private let defaults: UserDefaults
    static let stageKey = "setupWizardStage"
    init(defaults: UserDefaults = .standard, host: HostPreflightModel = HostPreflightModel()) {
        self.defaults = defaults; self.host = host
        stage = defaults.string(forKey: Self.stageKey).flatMap(SetupStage.init(rawValue:)) ?? .checkThisMac
    }
    var canGoNext: Bool { stage == .checkThisMac && host.canProceed }
    var canGoBack: Bool { stage != .checkThisMac && !host.isChecking }
    func next() {
        guard canGoNext else { return }
        stage = .createDevelopmentMac; defaults.set(stage.rawValue, forKey: Self.stageKey)
        host.invalidate()
    }
    func back() {
        guard canGoBack, let index = SetupStage.allCases.firstIndex(of: stage), index > 0 else { return }
        stage = SetupStage.allCases[index - 1]; defaults.set(stage.rawValue, forKey: Self.stageKey)
        if stage == .checkThisMac { host.invalidate() }
    }
}

struct SetupWizardView: View {
    @State private var model: SetupWizardModel
    @Environment(\.dismiss) private var dismiss
    init(model: SetupWizardModel = SetupWizardModel()) { _model = State(initialValue: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up a development Mac").font(.title2)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(SetupStage.allCases.enumerated()), id: \.element) { index, stage in
                        Text("\(index + 1). \(stage.title)")
                            .fontWeight(stage == model.stage ? .semibold : .regular)
                            .foregroundStyle(stage == model.stage ? .primary : .secondary)
                            .accessibilityLabel(stage.title + (stage == model.stage ? ", current step" : ", not completed"))
                    }
                }.frame(width: 190, alignment: .leading)
                ScrollView {
                    if model.stage == .checkThisMac { HostPreflightView(model: model.host) }
                    else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.stage.title).font(.headline)
                            Text("This setup step is not available yet. No development Mac has been created or changed by this wizard.")
                            Text("Guesthouse still needs an accepted, verified VM provider and the remaining setup integration. You can go back to check this Mac or close setup.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Divider()
            HStack {
                Button("Back") { model.back() }.disabled(!model.canGoBack)
                Spacer()
                Button("Close") { model.host.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Next") { model.next() }.disabled(!model.canGoNext).keyboardShortcut(.defaultAction)
            }
            Text("Closing setup preserves its place. Checks run again when you return to the first step; no VM job resumes automatically.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 760, height: 620)
        .task(id: model.stage) { if model.stage == .checkThisMac { await model.host.check().value } }
        .onDisappear { model.host.cancel() }
    }
}
