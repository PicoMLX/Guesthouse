import AppKit
import SwiftUI
import GuesthouseCore

/// The diagnostics and repair sheet: a filterable, read-only, copyable view of the redacted
/// log and an export to a folder the user chooses (MVP-PLAN.md §2 "Essential screens"; §3
/// "Local storage": nothing sensitive leaves the Mac, and environments are named by UUID).
struct DiagnosticsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var exportNote: String?

    /// What the sheet shows is what an export would contain: addresses and account names are
    /// scrubbed before anything is rendered, filtered, or copied.
    private var visibleLines: [String] {
        let lines = model.diagnosticsLines.map { DiagnosticsExportBuilder.scrub($0.text) }
        guard !filter.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.headline)
            Text("Redacted output from the runtime and the development Mac. Private keys, tokens, device codes, authorization headers, and network addresses are never shown or exported.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter log lines")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if visibleLines.isEmpty {
                        Text(filter.isEmpty ? "No log lines yet." : "No lines match the filter.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 220)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Log, \(visibleLines.count) lines")
            if let exportNote {
                Text(exportNote).font(.callout).foregroundStyle(.secondary).accessibilityLabel("Export result: \(exportNote)")
            }
            HStack {
                Button("Copy") { copyVisible() }
                    .disabled(visibleLines.isEmpty)
                    .accessibilityLabel("Copy visible lines")
                Button("Export diagnostics…") { export() }
                    .accessibilityLabel("Export diagnostics")
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private func copyVisible() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // The pasteboard is shared with every other application: what leaves the sheet is
        // scrubbed exactly like the written bundle.
        pasteboard.setString(visibleLines.joined(separator: "\n"), forType: .string)
        exportNote = "\(visibleLines.count) lines copied."
    }

    /// Writes the bundle as a folder the user names, through the sandbox-friendly save panel.
    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = "Guesthouse Diagnostics \(Self.stamp(Date()))"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsExportWriter.write(model.diagnosticsExport(), to: url)
            exportNote = "Exported to \(url.lastPathComponent): manifest.json, log.txt, and excluded.txt."
        } catch {
            exportNote = "The export could not be written (\(GuesthouseError.sanitize(error.localizedDescription, limit: 120))). Choose another location or free disk space."
        }
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, timeSeparator: .omitted)).replacingOccurrences(of: ":", with: "")
    }
}

#Preview("Diagnostics") {
    ScenarioPreview { await PreviewScenarios.oneRunningEnvironment() }
}
