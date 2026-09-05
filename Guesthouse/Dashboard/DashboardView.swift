import SwiftUI
import GuesthouseCore

/// The main window's content once the runtime has been reconciled: one or two environment
/// cards, an empty state that leads to the setup wizard, and the two-slot cap explained.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showingWizard = false
    @State private var showingDiagnostics = false
    /// Which environment the sheet is about, so Export writes the failing development Mac's
    /// evidence rather than whichever environment was created first.
    @State private var diagnosticsSubject: EnvironmentID?

    var body: some View {
        let cards = model.cardStates()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if cards.isEmpty {
                    EmptyDashboardView(availability: model.createAvailability, openDiagnostics: { diagnosticsSubject = nil; showingDiagnostics = true }) { showingWizard = true }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(cards) { card in
                            EnvironmentCardView(
                                state: card,
                                start: { model.start(card.id) },
                                cancel: { model.cancel(card.id) },
                                recover: { model.perform($0, for: card.id) },
                                openDiagnostics: { diagnosticsSubject = card.id; showingDiagnostics = true }
                            )
                        }
                        SlotView(availability: model.createAvailability) { showingWizard = true }
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showingWizard) { WizardPlaceholderView() }
        .sheet(isPresented: $showingDiagnostics) { DiagnosticsView(model: model, subject: diagnosticsSubject) }
    }
}

struct EmptyDashboardView: View {
    let availability: EnvironmentCardState.Availability
    let openDiagnostics: () -> Void
    let create: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 40)).foregroundStyle(.tint)
            Text("No development Mac yet").font(.title2)
            Text("Guesthouse creates a private macOS virtual machine with Xcode and your workspace, ready for Codex.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            AvailabilityButton("Create a development Mac", availability: availability, action: create)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Create a development Mac")
            // Diagnostics are reachable with no environment too: a fresh install that cannot
            // get further still needs the screen that says what Guesthouse saw.
            Button("Diagnostics…", action: openDiagnostics).accessibilityLabel("Open diagnostics")
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

/// The free slot, or the explanation of the cap when both are taken.
struct SlotView: View {
    let availability: EnvironmentCardState.Availability
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch availability {
            case .enabled:
                Text("Free slot").font(.headline)
                Text("One more development Mac can be created.").foregroundStyle(.secondary)
                Button("Create a development Mac", action: create).accessibilityLabel("Create a development Mac")
            case .disabled(let reason), .notImplemented(let reason):
                Text("No free slot").font(.headline)
                Text(reason).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct EnvironmentCardView: View {
    let state: EnvironmentCardState
    let start: () -> Void
    let cancel: () -> Void
    let recover: (RecoveryAction) -> Void
    let openDiagnostics: () -> Void
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let progress = state.progress {
                OperationProgressView(presentation: progress, cancel: cancel)
            }
            if let recovery = state.recovery {
                ErrorRecoveryView(presentation: recovery, perform: recover)
            }
            if !state.logs.isEmpty {
                LogDisclosureView(lines: state.logs)
            }
            detailsGrid
            actionsRow
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).accessibilityLabel("Note: \(note)")
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(state.name).font(.title3).bold()
            Spacer()
            if state.isBusy {
                // A phase that measures itself shows how far it is; the rest stay indeterminate.
                if let fraction = state.phase?.fraction {
                    ProgressView(value: fraction).controlSize(.small).frame(width: 60).accessibilityLabel("Busy, \(Int(fraction * 100)) percent")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Busy")
                }
            }
            Text(state.statusText).foregroundStyle(state.attention == nil ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
    }

    private var detailsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(state.details) { detail in
                GridRow {
                    Text(detail.label).foregroundStyle(.secondary)
                    Text(detail.value)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(detail.label): \(detail.value)")
            }
        }
        .font(.callout)
    }

    /// The actions wrap: at the adaptive grid's narrow column two cards leave roughly a third
    /// of the window for each, which is not enough for these labels on one line.
    private var actionsRow: some View {
        HStack(alignment: .top, spacing: 8) {
            WrappingHStack(spacing: 8, lineSpacing: 8) { actionButtons }
            Spacer(minLength: 8)
            overflowMenu
        }
    }

    @ViewBuilder private var actionButtons: some View {
        AvailabilityButton("Start", availability: state.availability(of: .start)) { perform(.start) }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Start")
        ForEach(secondaryPrimaryActions) { action in
            AvailabilityButton(action.title, availability: state.availability(of: action)) { perform(action) }
                .buttonStyle(.bordered)
                .accessibilityLabel(action.title)
        }
    }

    private var secondaryPrimaryActions: [EnvironmentCardState.Action] {
        EnvironmentCardState.Action.allCases.filter { $0.isPrimary && $0 != .start }
    }

    private var overflowMenu: some View {
        Menu {
            Button(EnvironmentCardState.Action.repair.title) { perform(.repair) }
            Button(EnvironmentCardState.Action.exportWork.title) { perform(.exportWork) }
            Button("Diagnostics…") { openDiagnostics() }
            Divider()
            Button(EnvironmentCardState.Action.delete.title, role: .destructive) { perform(.delete) }
        } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More actions")
    }

    private func perform(_ action: EnvironmentCardState.Action) {
        switch state.availability(of: action) {
        case .enabled:
            note = nil
            if action == .start { start() }
        case .disabled(let reason):
            note = reason
        case .notImplemented(let text):
            note = "\(action.title) is not implemented yet. \(text)"
        }
    }
}

/// A button that stays visible when its action is unavailable and explains why.
struct AvailabilityButton: View {
    let title: String
    let availability: EnvironmentCardState.Availability
    /// `.destructive` for an action that removes work, so it never looks like a routine fix.
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String, availability: EnvironmentCardState.Availability, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.availability = availability
        self.role = role
        self.action = action
    }

    var body: some View {
        switch availability {
        case .enabled:
            Button(title, role: role, action: action)
        case .disabled(let reason):
            Button(title, role: role, action: action)
                .disabled(true)
                .help(reason)
                .accessibilityHint(reason)
        case .notImplemented(let note):
            Button(title, role: role, action: action)
                .help("Not implemented yet. \(note)")
                .accessibilityHint("Not implemented yet")
        }
    }
}

/// Stands in for the setup wizard until #31 lands.
struct WizardPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a development Mac").font(.headline)
            Text("The setup wizard is not implemented yet. It will check this Mac, create the virtual machine, finish macOS setup, connect securely, add Xcode, sign in, add a workspace, and validate the Codex handoff (MVP-PLAN.md §2).")
                .foregroundStyle(.secondary)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Previews

/// Loads a `PreviewScenarios` case into a model and shows the dashboard over it.
struct ScenarioPreview: View {
    let load: @Sendable () async -> PreviewScenario
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model {
                DashboardView().environment(model)
            } else {
                ProgressView()
            }
        }
        .frame(width: 780, height: 520)
        .task { model = await AppModel.preview(load()) }
    }
}

#Preview("Fresh Mac") { ScenarioPreview { await PreviewScenarios.freshMac() } }
#Preview("One running environment") { ScenarioPreview { await PreviewScenarios.oneRunningEnvironment() } }
#Preview("Environment needing repair") { ScenarioPreview { await PreviewScenarios.environmentNeedingRepair() } }
#Preview("Both slots full") { ScenarioPreview { await PreviewScenarios.bothSlotsFull() } }
#Preview("Operation in progress") { ScenarioPreview { await PreviewScenarios.operationInProgress() } }


struct WrappingRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, within: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, within: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, within width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
