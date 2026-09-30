import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import GuesthouseClientKit
import GuesthouseCore

/// Native selection and scoped access only; validation remains in the runtime (MVP §§2–3).
struct XcodeSelectionView: View {
    @State private var panel: NSOpenPanel?
    @State private var check: Task<Void, Never>?
    @State private var outcome: RuntimeXcodeInspectionQuery.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose Xcode…", action: choose)
                    .disabled(panel != nil || check != nil)
                    .accessibilityIdentifier("chooseXcode")
                if check != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Inspecting Xcode")
                    Button("Cancel", action: cancel).disabled(check?.isCancelled == true)
                }
            }
            Text("Choose the Xcode application to inspect before preparing your development Mac.")
                .foregroundStyle(.secondary)
            if let outcome {
                switch outcome {
                case .success(let candidate):
                    Text("Xcode \(candidate.version.description), build \(candidate.build)").font(.headline)
                    Text(Self.sizeDescription(for: candidate.sizeEstimateBytes))
                    Text("Selection inspected. Copying Xcode and checking guest compatibility are separate steps.")
                        .foregroundStyle(.secondary)
                case .failure(let error):
                    Text(error.userMessage)
                    Text(error.recoveryMessage).foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("xcodeSelectionResult")
        .onDisappear(perform: cancel)
    }

    static func sizeDescription(for bytes: UInt64?) -> String {
        guard let bytes else { return "Disk usage could not be estimated." }
        let formatted = Int64(exactly: bytes).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? "\(bytes.formatted()) bytes"
        return "Estimated disk usage: \(formatted)"
    }

    private func choose() {
        guard panel == nil, check == nil else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.treatsFilePackagesAsDirectories = false
        picker.resolvesAliases = false
        picker.prompt = "Inspect Xcode"
        panel = picker
        picker.begin { response in
            // Cancel/disappearance clears ownership before a late panel callback can start work.
            guard panel === picker else { return }
            panel = nil
            guard response == .OK, let url = picker.url else { return }
            outcome = nil
            check = Task {
                let result = await XcodeSelectionRead.run(url: url)
                outcome = Task.isCancelled ? .failure(.canceled) : result
                check = nil
            }
        }
    }

    private func cancel() {
        let pending = panel
        panel = nil
        pending?.cancel(nil)
        guard let check else { return }
        check.cancel()
        outcome = .failure(.canceled)
        // Keep occupied until query cleanup completes, so late replies cannot replace a new selection.
    }
}

/// The GUI opens only the user-selected bundle, with read-only permission and no link follow.
/// Keep security scope and the handle alive through the complete query/cleanup operation.
enum XcodeSelectionRead {
    @concurrent static func run(url: URL) async -> RuntimeXcodeInspectionQuery.Outcome {
        guard !Task.isCancelled else { return .failure(.canceled) }
        guard url.isFileURL else { return .failure(.selection(.unavailable)) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(.selection(.unavailable)) }
        defer { close(descriptor) }
        do {
            let selection = try XcodeSelectionAccess(borrowing: descriptor)
            return await RuntimeXcodeInspectionQuery.run(selection: selection)
        } catch { return .failure(.selection(error)) }
    }
}
