import Foundation
import GuesthouseCore
import Observation

/// The ordered stages of first-launch setup (MVP-PLAN.md §2 "First launch"). The current
/// stage is persisted so the wizard resumes where it stopped.
enum SetupStage: String, CaseIterable, Codable, Identifiable {
    case checkThisMac
    case createDevelopmentMac
    case finishMacOSSetup
    case connectSecurely
    case addXcode
    case signIn
    case addWorkspace
    case validateAndOpen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .checkThisMac: "Check this Mac"
        case .createDevelopmentMac: "Create the development Mac"
        case .finishMacOSSetup: "Finish macOS setup"
        case .connectSecurely: "Connect securely"
        case .addXcode: "Add Xcode"
        case .signIn: "Sign in"
        case .addWorkspace: "Add a workspace"
        case .validateAndOpen: "Validate and open in Codex"
        }
    }

    /// Only the first stage has content so far; the rest say so.
    var isImplemented: Bool { self == .checkThisMac }
}

/// Runs the "Check this Mac" step and decides whether setup may continue.
@Observable
@MainActor
final class CheckThisMacModel {
    struct Row: Equatable, Identifiable {
        enum Verdict: Equatable { case pass, warn, undetermined, fail }
        let kind: PreflightCheckKind
        let title: String
        let verdict: Verdict
        let detail: String
        /// Recovery options for a warning or failure; empty for a pass.
        let recovery: [RecoveryPresentation.Option]
        var id: PreflightCheckKind { kind }
    }

    private(set) var report: PreflightReport?
    private(set) var isChecking = false
    private let probe: any HostProbe
    /// How the account's canonical root is resolved. Called once per check, never cached: the
    /// lookup reads the account record, which can fail transiently, and an answer held for the
    /// life of the process would leave the disk check undetermined behind a "Try again" that
    /// could only repeat the failure (AGENTS.md: every error carries a recovery that works).
    /// It still answers nil when the record cannot be read, which leaves the disk check
    /// undetermined rather than naming a path the runtime will not use.
    private let resolveStorageRoot: @Sendable () -> URL?
    private let volumeProbe: URL
    private let policy: ResourcePolicy
    /// Identifies one check. A recovery action can start a second check while the first is
    /// still running, and only the newest may publish.
    private var checkGeneration: UInt64 = 0

    init(
        probe: any HostProbe = SystemHostProbe(),
        storageRoot: @escaping @Sendable () -> URL? = CheckThisMacModel.defaultStorageRoot,
        volumeProbe: URL = CheckThisMacModel.defaultVolumeProbe,
        policy: ResourcePolicy = .standard
    ) {
        self.probe = probe
        self.resolveStorageRoot = storageRoot
        self.volumeProbe = volumeProbe
        self.policy = policy
    }

    /// Where the runtime keeps its data. The path is shown so the user knows where the VM will
    /// live, and its volume is what the disk check measures. It is the runtime's canonical
    /// root, not this app's container, which is what `FileManager`'s own home directory would
    /// name here (MVP-PLAN.md §3, "Local storage"). nil when the account record could not be
    /// read: the step then says the location is undetermined instead of showing the wrong one.
    nonisolated static func defaultStorageRoot() -> URL? { RuntimeStorageLocation.defaultRoot() }

    /// Where the disk check actually looks. A signed build is sandboxed, so the runtime's root
    /// is outside the container and outside what `Guesthouse.entitlements` grants: probing it
    /// fails the destination's own write check and leaves the disk verdict undetermined, which
    /// blocks step 1 with a retry that can only be denied again. This process's home is inside
    /// the container and under the same account home as the runtime's root, so it names the
    /// same volume, and the volume is what the check is about.
    static let defaultVolumeProbe = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    func check() {
        checkGeneration &+= 1
        let generation = checkGeneration
        isChecking = true
        let probe = probe, resolveStorageRoot = resolveStorageRoot, volumeProbe = volumeProbe, policy = policy
        Task.detached {
            // Resolved inside the check, so a lookup that failed once is retried by the very
            // action the undetermined disk row offers.
            let report = PreflightCheck.run(probe: probe, policy: policy, storageRoot: resolveStorageRoot(), measuredAt: volumeProbe)
            await MainActor.run {
                // A check that has been superseded publishes nothing: its answer is older than
                // the one on screen, and clearing `isChecking` would enable Next over a result
                // the newest check has not confirmed.
                guard generation == self.checkGeneration else { return }
                self.report = report
                self.isChecking = false
            }
        }
    }

    /// A report that is being re-checked no longer vouches for anything: Next waits for the
    /// fresh result.
    var canProceed: Bool { !isChecking && (report?.canProceed ?? false) }

    /// What the step says while it is working, or nil when it is not. A refresh over an
    /// existing report says so too: its rows stay on screen as the previous answer, and
    /// without this the only sign that they no longer stand is Next going dim.
    var progressMessage: String? {
        guard isChecking else { return nil }
        return report == nil ? "Checking this Mac…" : "Checking this Mac again…"
    }

    var rows: [Row] {
        guard let report else { return [] }
        return report.results.map { result in
            switch result.outcome {
            case .pass(let detail):
                Row(kind: result.kind, title: Self.title(for: result.kind), verdict: .pass, detail: detail.value, recovery: [])
            case .warn(let detail, let recovery):
                Row(kind: result.kind, title: Self.title(for: result.kind), verdict: .warn, detail: detail.value, recovery: Self.presentable(recovery.map { RecoveryPresentation.option(for: $0, outcomeUnknown: false) }))
            case .undetermined(let detail, let recovery):
                Row(kind: result.kind, title: Self.title(for: result.kind), verdict: .undetermined, detail: detail.value, recovery: Self.presentable(recovery.map { RecoveryPresentation.option(for: $0, outcomeUnknown: false) }))
            case .fail(let error):
                Row(kind: result.kind, title: Self.title(for: result.kind), verdict: .fail, detail: error.userMessage, recovery: Self.presentable(RecoveryPresentation(error: error).options))
            }
        }
    }

    /// "What will be downloaded and where the VM will live" (MVP-PLAN.md §2, step 1).
    var storageSummary: [String] {
        guard let storage = report?.storage else { return [] }
        let format: (UInt64) -> String = { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }
        // The location line is omitted when the root is unknown rather than filled in with a
        // guess: the disk check is already undetermined in that case, and naming this app's
        // container would tell the user the runtime writes somewhere it never will.
        let location = storage.storageRootPath.map { "Everything lives under \($0)." }
            ?? "Guesthouse could not determine where the development Mac would be stored."
        return [
            "The virtual machine runtime download is about \(format(storage.runtimeDownloadEstimateBytes)).",
            "The macOS restore image download is about \(format(storage.restoreImageEstimateBytes)).",
            "The development Mac's disk can grow to \(format(storage.guestDiskBytes)); setup needs \(format(storage.firstSetupAllowanceBytes)) free.",
            location,
        ] + (report?.powerSource == .battery ? ["This Mac is on battery power. Setup downloads and installs a lot; plug it in first."] : [])
    }

    /// "Dismiss" means nothing inside a check row, but the action behind it does: closing
    /// setup. It is retitled so the button says what it will do, and the view closes the
    /// sheet when it is chosen. Some checks (an Intel Mac) have no other action.
    static func presentable(_ options: [RecoveryPresentation.Option]) -> [RecoveryPresentation.Option] {
        options.map { option in
            option.action == .cancel
                ? RecoveryPresentation.Option(action: .cancel, title: "Close setup", availability: .enabled)
                : option
        }
    }

    static func title(for kind: PreflightCheckKind) -> String {
        switch kind {
        case .architecture: "Processor"
        case .macOSVersion: "macOS version"
        case .memory: "Memory"
        case .freeDisk: "Free disk space"
        case .codexDesktop: "Codex desktop"
        }
    }
}

/// The wizard container: an ordered stage model with a persisted position and back/next rules.
@Observable
@MainActor
final class SetupWizardModel {
    static let stageKey = "setupWizard.stage"

    private(set) var current: SetupStage
    let checkThisMac: CheckThisMacModel
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, checkThisMac: CheckThisMacModel = CheckThisMacModel()) {
        self.defaults = defaults
        self.checkThisMac = checkThisMac
        current = Self.persistedStage(in: defaults)
    }

    /// The wizard is being shown. The position is read again, because setup may have advanced
    /// since this model was made, and the host is checked again, because a report from an
    /// earlier presentation cannot vouch for conditions that changed while the sheet was
    /// closed (MVP-PLAN.md §2, "First launch").
    func presented() {
        current = Self.persistedStage(in: defaults)
        checkThisMac.check()
    }

    private static func persistedStage(in defaults: UserDefaults) -> SetupStage {
        defaults.string(forKey: stageKey).flatMap(SetupStage.init(rawValue:)) ?? .checkThisMac
    }

    var stages: [SetupStage] { SetupStage.allCases }

    var canGoBack: Bool { current != .checkThisMac }

    /// Next is offered only when the current stage is complete: the checks must all pass, and
    /// unimplemented stages cannot be completed yet.
    var canGoNext: Bool {
        switch current {
        case .checkThisMac: checkThisMac.canProceed
        default: false
        }
    }

    func next() {
        guard canGoNext, let index = stages.firstIndex(of: current), index + 1 < stages.count else { return }
        move(to: stages[index + 1])
    }

    func back() {
        guard canGoBack, let index = stages.firstIndex(of: current), index > 0 else { return }
        move(to: stages[index - 1])
    }

    private func move(to stage: SetupStage) {
        current = stage
        defaults.set(stage.rawValue, forKey: Self.stageKey)
    }
}
