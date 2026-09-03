import Foundation
import GuesthouseCore
import Observation

/// The app's top-level state: what the runtime reports, and the Quit contract.
///
/// MVP-PLAN.md §2 ("Returning developer"): closing the window keeps Guesthouse running in the
/// menu bar; normal Quit offers "Stop environments and quit" or "Cancel", waits for the guest
/// and Tart to stop, and offers cancellation or an explicitly warned force-stop if graceful
/// stop fails; after a crash or disconnection the app shows "Checking environment" rather than
/// a cached Ready state and reconciles before offering new operations.
@Observable
final class AppModel {
    enum LaunchState: Equatable {
        /// Reconciling with the runtime; no operations are offered.
        case checkingEnvironment
        case ready
        /// The runtime connection dropped; in-flight outcomes are unknown until re-checked.
        case interrupted(RuntimeConnectionInterrupted)
        case unavailable(GuesthouseError)
    }

    enum QuitFlow: Equatable {
        case idle
        /// The sheet is showing its two options.
        case confirming
        /// Environments are being stopped; the app has told AppKit to wait.
        case stopping(EnvironmentID?, ProgressPhase?)
        /// Graceful stop failed; the sheet offers the warned force-stop or cancel.
        case stopFailed(GuesthouseError)
        case forceStopping(EnvironmentID?)
        /// Everything stopped; AppKit has been told to terminate.
        case terminating
    }

    static let gracefulStopDeadline: Duration = .seconds(60)

    private(set) var launchState: LaunchState = .checkingEnvironment
    private(set) var environments: [DevelopmentEnvironment] = []
    private(set) var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    private(set) var quitFlow: QuitFlow = .idle
    /// Shown alongside the Quit sheet: external Codex work cannot be enumerated.
    let quitWarning = "Stopping a development Mac interrupts any Codex task running in it. Guesthouse cannot see those tasks; finish them first."

    let backend: any RuntimeBackend
    private let terminationDecision: @MainActor (Bool) -> Void
    private var quitTask: Task<Void, Never>?

    /// - Parameters:
    ///   - backend: the runtime, or a fake for previews and tests.
    ///   - terminationDecision: how the final Quit decision reaches AppKit
    ///     (`NSApplication.reply(toApplicationShouldTerminate:)` in the app).
    init(backend: any RuntimeBackend, terminationDecision: @escaping @MainActor (Bool) -> Void) {
        self.backend = backend
        self.terminationDecision = terminationDecision
    }

    /// Picks the real client, or the fake when `GUESTHOUSE_FAKE_RUNTIME=1` or when the app is
    /// hosting unit tests, so a test run never launches the runtime service.
    static func makeBackend(environment: [String: String] = ProcessInfo.processInfo.environment) -> any RuntimeBackend {
        if environment["GUESTHOUSE_FAKE_RUNTIME"] == "1" || environment["XCTestConfigurationFilePath"] != nil {
            return FakeRuntimeBackend()
        }
        return RuntimeClient()
    }

    // MARK: - Reconciliation

    /// Re-reads everything from the runtime. Never trusts a cached Ready.
    func refresh() async {
        launchState = .checkingEnvironment
        do {
            var listed: [DevelopmentEnvironment] = []
            for try await event in backend.send(.listEnvironments) {
                switch event {
                case .environments(let environments): listed = environments
                case .failed(_, let error): launchState = .unavailable(error); return
                default: break
                }
            }
            var fresh: [EnvironmentID: EnvironmentStatus] = [:]
            for environment in listed {
                for try await event in backend.send(.environmentStatus(environment.id)) {
                    if case .status(let status) = event { fresh[environment.id] = status }
                    if case .failed(_, let error) = event { launchState = .unavailable(error); return }
                }
            }
            environments = listed
            statuses = fresh
            launchState = .ready
        } catch let error as RuntimeConnectionInterrupted {
            launchState = .interrupted(error)
        } catch {
            launchState = .interrupted(RuntimeConnectionInterrupted())
        }
    }

    var runningEnvironments: [DevelopmentEnvironment] {
        environments.filter { statuses[$0.id]?.vm == .running }
    }

    // MARK: - Quit contract

    /// AppKit asked whether to terminate. Returns false when the sheet must be shown first.
    func handleQuitRequest() -> Bool {
        switch quitFlow {
        case .terminating: return true
        case .idle: quitFlow = .confirming; return false
        default: return false
        }
    }

    /// The user chose "Stop environments and quit".
    func confirmStopAndQuit() {
        guard case .confirming = quitFlow else { return }
        quitTask = Task { await stopAll(mode: .graceful(deadline: Self.gracefulStopDeadline)) }
    }

    /// The user accepted the force-stop warning.
    func forceStopAndQuit() {
        guard case .stopFailed = quitFlow else { return }
        quitTask = Task { await stopAll(mode: .force) }
    }

    /// The user canceled from any sheet state. A stop already under way keeps running until
    /// its current phase ends, then the app stays open.
    func cancelQuit() {
        quitTask?.cancel()
        quitTask = nil
        quitFlow = .idle
        terminationDecision(false)
    }

    private func stopAll(mode: StopMode) async {
        let targets = runningEnvironments
        for environment in targets {
            if Task.isCancelled { return }
            quitFlow = mode == .force ? .forceStopping(environment.id) : .stopping(environment.id, nil)
            do {
                for try await event in backend.send(.stopEnvironment(environment.id, mode)) {
                    switch event {
                    case .progress(_, let phase):
                        if case .stopping = quitFlow { quitFlow = .stopping(environment.id, phase) }
                    case .status(let status):
                        statuses[status.environmentID] = status
                    case .failed(_, let error):
                        quitFlow = .stopFailed(error)
                        return
                    default:
                        break
                    }
                }
            } catch {
                launchState = .interrupted(RuntimeConnectionInterrupted())
                quitFlow = .stopFailed(.operationOutcomeUnknown(OperationID()))
                return
            }
        }
        quitFlow = .terminating
        terminationDecision(true)
    }
}
