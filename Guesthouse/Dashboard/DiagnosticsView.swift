import AppKit
import SwiftUI
import GuesthouseCore

/// The diagnostics and repair sheet: a filterable, read-only, copyable view of the redacted
/// log and an export to a folder the user chooses (MVP-PLAN.md §2 "Essential screens"; §3
/// "Local storage": nothing sensitive leaves the Mac, and environments are named by UUID).
struct DiagnosticsView: View {
    @Bindable var model: AppModel
    /// The environment whose card opened the sheet, or nil when it was opened from the
    /// toolbar. It decides which environment the log and the exported bundle describe.
    var subject: EnvironmentID?
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var exportNote: String?

    /// What the sheet shows is what an export would contain: the model has already scrubbed
    /// addresses and account names out of these lines, so only the filter is applied here.
    /// Scrubbing again would run every address and identity pattern over the whole log a
    /// second time, on the UI actor, for no change in what is rendered.
    private var visibleLines: [String] {
        let lines = model.diagnosticsLines(subject: subject).map(\.text)
        guard !filter.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        // Read once. The empty check, the rows, the accessibility count, and the Copy button
        // all need the same list, and each read of the property rebuilds and rescrubs the
        // whole retained log — up to 500 records of up to 64 KiB each, synchronously.
        let lines = visibleLines
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.headline)
            Text("Redacted output from the runtime and the development Mac. Private keys, tokens, device codes, authorization headers, and network addresses are never shown or exported.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter log lines")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text(filter.isEmpty ? "No log lines yet." : "No lines match the filter.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { entry in
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
            .accessibilityLabel("Log, \(lines.count) lines")
            if let exportNote {
                Text(exportNote).font(.callout).foregroundStyle(.secondary).accessibilityLabel("Export result: \(exportNote)")
            }
            HStack {
                Button("Copy") { copyVisible(lines) }
                    .disabled(lines.isEmpty)
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

    private func copyVisible(_ lines: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // The pasteboard is shared with every other application: what leaves the sheet is
        // scrubbed exactly like the written bundle.
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        exportNote = "\(lines.count) lines copied."
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
            try DiagnosticsExportWriter.write(model.diagnosticsExport(subject: subject), to: url)
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
