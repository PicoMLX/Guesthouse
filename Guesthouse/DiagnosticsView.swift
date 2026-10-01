import AppKit
import SwiftUI
import GuesthouseCore

/// A stable snapshot keeps selection attached to the records the user actually saw.
struct DiagnosticsView: View {
    let environment: EnvironmentID?
    let currentHistory: () -> DiagnosticLog
    @State private var history: DiagnosticLog
    @State private var query = ""
    @State private var selection: Set<Int> = []
    @State private var panel: NSSavePanel?
    @State private var saving = false
    @State private var outcome: SaveOutcome?
    @Environment(\.dismiss) private var dismiss

    init(environment: EnvironmentID? = nil, history: DiagnosticLog, currentHistory: @escaping () -> DiagnosticLog) {
        self.environment = environment; self.currentHistory = currentHistory
        _history = State(initialValue: environment.map { history.selecting(environments: [$0]) } ?? history)
    }
    private var records: [DiagnosticLog.Record] { DiagnosticsSelection.records(in: history, matching: query) }
    private var busy: Bool { saving || panel != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title2)
            Text(environment.map { "Environment \($0.description)" } ?? "Current Guesthouse session").font(.caption)
            Text(DiagnosticsExportBuilder.historyNotice).font(.caption).foregroundStyle(.secondary)
            Text("\(history.records.count) retained records; \(history.discardedCount) local session evictions.").font(.caption)
            HStack {
                TextField("Filter structured events", text: $query)
                Button("Refresh snapshot") {
                    let current = currentHistory()
                    history = environment.map { current.selecting(environments: [$0]) } ?? current
                    selection.removeAll(); outcome = nil
                }.disabled(busy)
            }
            List(selection: $selection) {
                ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.recordedAt, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                        Text(record.event.message)
                        if let recovery = record.event.recoveryMessage { Text(recovery).foregroundStyle(.secondary) }
                        if environment == nil {
                            Text(record.event.environmentID.map { "Environment \($0.description)" } ?? "Session-wide event").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(record.event.operationID.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.tag(index).padding(.vertical, 3)
                }
            }.overlay { if records.isEmpty { ContentUnavailableView("No matching diagnostic events", systemImage: "list.bullet.rectangle") } }
            Text("Export includes the complete environment/session snapshot above, independent of the text filter or row selection. Raw process output and private status are excluded.").font(.caption).foregroundStyle(.secondary)
            if let outcome { Text(outcome.message).textSelection(.enabled) }
            HStack {
                Button("Copy selected records") {
                    guard let text = DiagnosticsSelection.text(in: history, matching: query, selection: selection) else { return }
                    NSPasteboard.general.clearContents()
                    outcome = NSPasteboard.general.setString(text, forType: .string) ? nil : .copyFailed
                }.disabled(selection.isEmpty)
                Button("Export diagnostics…", action: export).disabled(busy)
                if saving { ProgressView().controlSize(.small).accessibilityLabel("Saving diagnostics") }
                Spacer()
                Button("Done") { dismiss() }.disabled(busy).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 580)
        .onChange(of: query) { selection.removeAll() }
        .interactiveDismissDisabled(busy)
        .onDisappear { let pending = panel; panel = nil; pending?.cancel(nil) }
    }
    private func export() {
        guard !busy else { return }
        let prepared: DiagnosticsExport
        do { prepared = try DiagnosticsExportBuilder.build(log: history, environmentIDs: environment.map { [$0] }) }
        catch { outcome = .preparation(error); return }
        outcome = nil
        let picker = NSSavePanel()
        picker.title = "Export diagnostics"
        picker.prompt = "Export"
        picker.nameFieldStringValue = "Guesthouse Diagnostics"
        picker.message = "Choose a new folder name for the structured diagnostic snapshot. Existing folders are never replaced."
        picker.canCreateDirectories = true
        panel = picker
        picker.begin { response in
            guard panel === picker else { return }
            panel = nil
            guard response == .OK, let url = picker.url else { return }
            saving = true
            Task {
                switch await DiagnosticsExportWriter.write(prepared, to: url) {
                case .success: outcome = .saved
                case .failure(let failure): outcome = .writing(failure)
                }
                saving = false
            }
        }
    }
    private enum SaveOutcome {
        case saved, copyFailed, preparation(DiagnosticsExportError), writing(DiagnosticsExportWriter.Failure)
        var message: String {
            switch self {
            case .saved: "Diagnostic snapshot saved."
            case .copyFailed: "Guesthouse could not copy the selected records. Select them again and retry Copy."
            case .preparation(let error): error.userMessage + " Refresh the snapshot and try again."
            case .writing(let error): error.userMessage + " " + error.recoveryMessage
            }
        }
    }
}

nonisolated enum DiagnosticsSelection {
    private static func matches(_ record: DiagnosticLog.Record, query: String) -> Bool {
        query.isEmpty || (record.event.message + " " + (record.event.recoveryMessage ?? "") + " "
            + record.event.operationID.uuidString + " " + (record.event.environmentID?.description ?? "")).localizedStandardContains(query)
    }
    static func records(in log: DiagnosticLog, matching query: String) -> [DiagnosticLog.Record] {
        log.records.filter { matches($0, query: query) }
    }
    static func text(in log: DiagnosticLog, matching query: String, selection: Set<Int>) -> String? {
        let visible = log.records.enumerated().filter { matches($0.element, query: query) }
        let indices = Set(selection.compactMap { visible.indices.contains($0) ? visible[$0].offset : nil })
        let selected = log.selecting(recordsAt: indices)
        return selected.records.isEmpty ? nil : "Selected diagnostic records only.\n" + DiagnosticsExportBuilder.historyNotice + "\n" + selected.text
    }
}
