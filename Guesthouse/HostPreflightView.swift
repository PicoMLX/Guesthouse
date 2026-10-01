import SwiftUI
import GuesthouseClientKit
import GuesthouseCore

/// Read-only host observations; no setup/start action consumes this report as authority.
struct HostPreflightView: View {
    @State private var model: HostPreflightModel
    init(model: HostPreflightModel = HostPreflightModel()) { _model = State(initialValue: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Check this Mac", action: { model.check() })
                    .disabled(model.isChecking)
                    .accessibilityIdentifier("checkThisMac")
                if model.isChecking {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking this Mac")
                    Button("Cancel", action: model.cancel).disabled(model.cancellationRequested)
                }
            }
            if let outcome = model.outcome {
                switch outcome {
                case .success(let report):
                    Text(report.canProceed ? "Host requirements checked." : "Some host requirements need attention.")
                        .font(.headline)
                    Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .standard)). Check again if this Mac changes.")
                        .foregroundStyle(.secondary)
                    ForEach(report.results, id: \.kind) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(result.userMessage, systemImage: result.severity == .pass ? "checkmark.circle" : result.isBlocking ? "exclamationmark.circle" : "info.circle")
                            Text(result.severity.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            if !result.recoveryActions.isEmpty {
                                Text(result.recoveryActions.map(\.title).joined(separator: "; ")).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(result.severity.rawValue + ": " + result.userMessage)
                        .accessibilityHint(result.recoveryActions.map(\.title).joined(separator: "; "))
                    }
                    Text("Planned runtime download: " + Self.bytes(report.storage.runtimeDownloadEstimateBytes))
                    Text("Planned macOS restore download: " + Self.bytes(report.storage.restoreImageEstimateBytes))
                    Text("Guest disk capacity: " + Self.bytes(report.storage.guestDiskBytes))
                    Text("First setup space allowance: " + Self.bytes(report.storage.firstSetupAllowanceBytes))
                    Text("These are planning estimates; the chosen provider and downloads must be verified before setup.").font(.caption)
                    if report.powerSource == .battery { Text("Connect this Mac to power before setup.") }
                    Text(report.storage.locationDescription).foregroundStyle(.secondary)
                    Text("Provider, guest and Codex connection verification is still required before development can begin.")
                        .foregroundStyle(.secondary)
                case .failure(let error):
                    Text(error.userMessage)
                    Text(error.recoveryMessage).foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("hostPreflightResult")
        .onDisappear(perform: model.cancel)
    }

    private static func bytes(_ value: UInt64) -> String {
        Int64(exactly: value).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "\(value.formatted()) bytes"
    }
}

#if DEBUG
private struct HostPreflightPreview: View {
    @State private var model: HostPreflightModel
    init(severity: PreflightResult.Severity) {
        let memory: PreflightResult = switch severity {
        case .pass: .memorySufficient(bytes: 32_000_000_000)
        case .warn: .memoryLimited(foundBytes: 16_000_000_000, recommendedBytes: 32_000_000_000)
        case .fail: .memoryFailure(.unsupportedHost(.insufficientMemory(foundBytes: 8_000_000_000, minimumBytes: 16_000_000_000)))
        case .undetermined: .memoryUnknown
        }
        let report = PreflightReport(results: [.architectureSupported(.appleSilicon), .macOSSupported(SemanticVersion("26.6")!), memory,
            .diskSufficient(bytes: 300_000_000_000), .codexInstalled(version: nil, build: nil)], storage: .init(), powerSource: severity == .warn ? .battery : .externalPower, checkedAt: Date())
        _model = State(initialValue: HostPreflightModel { .success(report) })
    }
    var body: some View { ScrollView { HostPreflightView(model: model).padding() }.frame(width: 480, height: 650).task { await model.check().value } }
}
#Preview("Host checks pass") { HostPreflightPreview(severity: .pass) }
#Preview("Host warnings") { HostPreflightPreview(severity: .warn) }
#Preview("Host check failure") { HostPreflightPreview(severity: .fail) }
#endif
