import SwiftUI
import GuesthouseCore

struct DashboardView: View {
    let model: AppModel, quit: QuitCoordinator
    @State private var showingCreation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EnvironmentCheckView(model: model, quit: quit)
            ForEach(model.environments) { environment in
                EnvironmentCardView(state: EnvironmentCardState(environment: environment,
                    status: model.statuses[environment.id], checked: model.checkState == .checked,
                    busy: model.isChecking || model.isStarting || quit.flow != .idle, backendAllowsStart: model.backend.allowsEnvironmentStart),
                    canStart: model.canStart(environment.id), start: { model.startEnvironment(environment.id) })
                if model.startingEnvironment == environment.id {
                    if model.isStarting { OperationProgressView(phase: model.startPhase, cancellationRequested: model.startCancellationRequested, cancel: model.startCanCancel ? { model.cancelStart() } : nil) }
                    if model.isStarting, let failure = model.startCancellationFailure {
                        Text("Cancellation request failed. " + failure.message + " The original operation is still being observed.").foregroundStyle(.secondary)
                        if model.startCanCancel && !model.startCancellationRequested {
                            Text("Use Cancel operation to request cancellation again. Guesthouse will inspect state after the operation and cancellation replies finish.").font(.caption)
                        }
                    }
                    if let failure = model.startFailure {
                        if model.startFailureDismissed {
                            Text("The last Start needs attention. Check the environment before continuing.").foregroundStyle(.secondary)
                        } else {
                            ErrorRecoveryView(presentation: .init(failure: failure), canRetry: model.canRetryStart(environment.id), canInspect: !model.isStarting && !model.isChecking && quit.flow == .idle) { action in
                                switch action {
                                case .retry: model.retryStart(environment.id)
                                case .inspectState: model.checkEnvironments()
                                case .cancel: model.dismissStartFailure()
                                default: break
                                }
                            }
                        }
                    }
                    DiagnosticDisclosureView(log: model.startDiagnostics)
                }
            }
            if let id = model.startingEnvironment, !model.environments.contains(where: { $0.id == id }), let failure = model.startFailure {
                Text(failure.message).foregroundStyle(.secondary)
            }
            if model.checkState == .checked {
                VStack(alignment: .leading, spacing: 6) {
                    if model.environments.isEmpty { Text("Create a development Mac").font(.title2) }
                    Button("Create development Mac…") { showingCreation = true }
                        .disabled(model.environments.count >= 2 || quit.flow != .idle || model.isChecking || model.isStarting)
                        .help(model.environments.count >= 2 ? "Guesthouse supports at most two development Macs." : "Open development Mac setup")
                    Text(model.environments.count >= 2
                         ? "Both slots are occupied. Saved work is retained; deletion is a separate action."
                         : "Guesthouse supports at most two development Macs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingCreation) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create a development Mac").font(.title2)
                Text("Environment creation is not available yet. You can check host requirements, prepare storage and select Xcode in Setup checks.")
                Button("Done") { showingCreation = false }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 420)
        }
    }
}

private struct EnvironmentCardView: View {
    let state: EnvironmentCardState
    let canStart: Bool
    let start: () -> Void
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(state.statusText).font(.headline)
                if let guidance = state.guidance { Text(guidance).foregroundStyle(.secondary) }
                Grid(alignment: .leading, horizontalSpacing: 20) {
                    ForEach(state.details) { detail in
                        GridRow { Text(detail.label); Text(detail.value).foregroundStyle(.secondary) }
                    }
                }.font(.callout)
                // No live capability transport exists yet. Saved readiness/tool versions do
                // not populate the #187 ledger or prove any of these independent capabilities.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(EnvironmentCapability.allCases, id: \.self) { capability in
                        LabeledContent(capability.dashboardTitle, value: "Not checked")
                    }
                }.font(.callout)
                ViewThatFits(in: .horizontal) {
                    HStack { primaryActions }
                    VStack(alignment: .leading) { primaryActions }
                }
                Menu("More actions") {
                    action(.repair); action(.exportWork)
                    Divider()
                    action(.startFresh); action(.delete)
                }.accessibilityLabel("More actions for \(state.name)")
                DisclosureGroup("Why actions are unavailable") {
                    ForEach(EnvironmentCardState.Action.allCases) { item in
                        Text("\(item.title): \(item == .start && canStart ? "Available after a fresh environment inspection." : state.reason(for: item))").font(.caption)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Text(state.name).font(.title3) }
        .textSelection(.enabled)
    }
    private var primaryActions: some View {
        ForEach(EnvironmentCardState.Action.allCases.filter(\.primary)) { action($0) }
    }
    private func action(_ item: EnvironmentCardState.Action) -> some View {
        Button(item.title, role: (item == .delete || item == .startFresh) ? .destructive : nil) { if item == .start { start() } }
            .disabled(item != .start || !canStart)
            .help(item == .start && canStart ? "Start this development Mac and retain saved work." : state.reason(for: item))
            .accessibilityLabel("\(item.title), \(state.name)")
            .accessibilityHint(item == .start && canStart ? "Inspects the environment before starting." : state.reason(for: item))
    }
}

#if DEBUG
private struct DashboardPreview: View {
    let index: Int
    @State private var model: AppModel?
    @State private var quit: QuitCoordinator?
    var body: some View {
        ScrollView {
            if let model, let quit { DashboardView(model: model, quit: quit).padding() }
            else { ProgressView() }
        }.frame(width: 680, height: 760).task {
            guard model == nil else { return }
            let scenario = await PreviewScenarios.all[index]()
            await scenario.backend.setEnvironmentInventory(.available(scenario.snapshot.environments))
            let created = AppModel(backend: scenario.backend)
            model = created; quit = QuitCoordinator(model: created) { _ in }
            await created.checkEnvironments().value
        }
    }
}
#Preview("Fresh Mac") { DashboardPreview(index: 0) }
#Preview("Running") { DashboardPreview(index: 1) }
#Preview("Needs repair") { DashboardPreview(index: 2) }
#Preview("Both slots full") { DashboardPreview(index: 3) }
#Preview("Operation in progress") { DashboardPreview(index: 4) }
#endif
