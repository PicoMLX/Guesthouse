import Foundation
import GuesthouseCore

/// Runs the verified Tart bundle with `TART_HOME` pinned to the VM store. The service, never
/// the client, chooses every executable path and flag here (MVP-PLAN.md §3).
public struct TartBackend: Sendable {
    public let bundle: TartBundle
    public let storage: RuntimeStorage
    public let runner: any ProcessRunning
    /// What the bundle was when the service verified it: the directory, its `Info.plist`, and
    /// the executable. Every launch checks that none of them has been replaced since, so
    /// neither an unsigned substitute nor another bundle built around the verified executable
    /// can be run.
    public let verifiedBundle: TartBundle.BundleIdentity?

    public init(bundle: TartBundle, storage: RuntimeStorage, runner: any ProcessRunning, verifiedBundle: TartBundle.BundleIdentity? = nil) {
        self.bundle = bundle
        self.storage = storage
        self.runner = runner
        self.verifiedBundle = verifiedBundle
    }

    /// The most records a parsed command may produce before its output is refused.
    static let maximumCapturedRecords = 512

    /// Refuses to launch when the bundle is not the one that passed verification.
    func requireVerifiedBundle() throws {
        guard let verifiedBundle else { return }
        guard bundle.identity == verifiedBundle else {
            throw TartInvocationError.runtimeReplaced
        }
    }

    /// Launches the verified executable. macOS has no `fexecve`, so a process cannot be
    /// started from an open descriptor: the runner opens the path. The window that leaves is
    /// closed from the other side instead. The identity is checked again the moment the child
    /// exists, and a process started from anything but the verified file is ended before it
    /// is spoken to, so a substitute never receives a request or reaches a VM.
    func launch(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        try requireVerifiedBundle()
        let run: ProcessRun
        do {
            run = try await runner.run(invocation)
        } catch {
            // The launch itself can fail because the file was removed, replaced, or made
            // unexecutable after the check above. That is an integrity failure, not a runtime
            // that verified and then would not start, and the caller has to be told which.
            try requireVerifiedBundle()
            throw error
        }
        do {
            try requireVerifiedBundle()
        } catch {
            run.terminate(gracePeriod: .seconds(1))
            _ = await run.exit()
            throw error
        }
        return run
    }

    /// The most records a parsed command may produce before its output is refused.
    static let maximumCapturedRecords = 512

    /// `tart --version`, parsed strictly. Anything unparseable is reported as a failure, never
    /// guessed.
    public func version() async throws -> TartVersion {
        let output = try await capture(["--version"], timeout: .seconds(15))
        // The parser's contract is one line, and it splits on newlines where `split` drops
        // empty subsequences: a leading or extra blank record would be parsed away and drifted
        // output read as the pin. The capture itself has to be that one line.
        guard !output.stdout.contains("\n"), let version = TartVersion(parsing: output.stdout) else {
            throw TartInvocationError.unparseableOutput
        }
        return version
    }

    /// `tart list --format json`: the inventory of the app-managed store only.
    public func list() async throws -> [TartVMInfo] {
        let output = try await capture(["list", "--format", "json"], timeout: .seconds(30))
        do {
            return try TartListParser.parse(output.stdout)
        } catch {
            throw TartInvocationError.unparseableOutput
        }
    }

    /// `tart ip <vm> --wait <seconds>`: the guest's address once it has one.
    public func ip(vmName: String, wait: Duration) async throws -> GuestIPAddress {
        let seconds = max(0, Int(wait.components.seconds))
        let output = try await capture(["ip", vmName, "--wait", String(seconds)], timeout: wait + .seconds(15))
        do {
            return try TartIPParser.parse(output.stdout)
        } catch {
            throw TartInvocationError.unparseableOutput
        }
    }

    /// `tart run <vm>`, headless unless the native console is requested. The returned run
    /// lives as long as the VM; the caller supervises it.
    public func run(vmName: String, console: StartOptions.ConsoleMode) async throws -> ProcessRun {
        var arguments = ["run", vmName]
        if console == .headless { arguments.append("--no-graphics") }
        return try await launch(ProcessInvocation(
            executable: bundle.executable,
            arguments: Self.runArguments(vmName: vmName, console: console),
            environment: storage.environmentForTart(),
            timeout: .seconds(60 * 60 * 24 * 365),
            terminationGracePeriod: .seconds(30)
        ))
    }

    /// The exact argument vector `run` uses, recorded with the process identity so a survivor
    /// is recognized after a relaunch.
    public static func runArguments(vmName: String, console: StartOptions.ConsoleMode) -> [String] {
        var arguments = ["run", vmName]
        if console == .headless { arguments.append("--no-graphics") }
        return arguments
    }

    /// `tart stop <vm>`: a graceful shutdown that waits up to `deadline`. Tart's own `--timeout`
    /// escalates to a force-stop, so it is set far beyond the deadline; when the deadline
    /// passes, the stop command is ended and `TartInvocationError.timedOut` is thrown with the
    /// guest still running. Force-stopping is a separate, warned path.
    public func stop(vmName: String, deadline: Duration) async throws {
        _ = try await capture(["stop", vmName, "--timeout", String(Self.neverForceSeconds)], timeout: deadline)
    }

    static let neverForceSeconds = 86_400

    // MARK: - Helpers

    struct Captured {
        let stdout: String
        let stderr: String
    }

    private func capture(_ arguments: [String], timeout: Duration) async throws -> Captured {
        let run = try await launch(ProcessInvocation(
            executable: bundle.executable,
            arguments: arguments,
            environment: storage.environmentForTart(),
            timeout: timeout
        ))
        // A canceled operation ends the query process too, so a start canceled while waiting
        // for the address does not keep `tart ip` waiting for its own timeout.
        let (stdout, stderr, exit) = await withTaskCancellationHandler {
            var stdout: [String] = []
            var stderr: [String] = []
            for await line in run.output {
                // A command whose output is parsed is bounded by record count as well as by
                // the runner's byte cap: empty records cost no bytes but still cost memory.
                guard stdout.count + stderr.count < Self.maximumCapturedRecords else { break }
                switch line {
                case .stdout(let text): stdout.append(text.text)
                case .stderr(let text): stderr.append(text.text)
                }
            }
            return (stdout, stderr, await run.exit())
        } onCancel: {
            run.terminate(gracePeriod: .seconds(1))
        }
        if Task.isCancelled { throw CancellationError() }
        if exit.timedOut { throw TartInvocationError.timedOut }
        // A truncated capture is not a complete answer: a parser must see all of stdout
        // before its result is trusted as the runtime's own.
        guard exit.succeeded else {
            throw TartInvocationError.failed(TartErrorClassifier.classify(stderr: stderr.joined(separator: "\n"), exitStatus: Self.exitStatus(exit)))
        }
        // A truncated capture is not a complete answer: a parser must see all of stdout
        // before its result is trusted as the runtime's own.
        guard !exit.outputTruncated else { throw TartInvocationError.unparseableOutput }
        return Captured(stdout: stdout.joined(separator: "\n"), stderr: stderr.joined(separator: "\n"))
    }

    static func exitStatus(_ exit: ProcessExit) -> Int32 {
        switch exit.reason {
        case .status(let status): status
        case .signal(let signal): 128 + signal
        }
    }
}

public enum TartInvocationError: Error, Hashable, Sendable {
    case failed(TartFailure)
    case unparseableOutput
    /// The executable is not the file that passed verification. Its own case, because an
    /// integrity failure is not an unknown version: the caller must report the bundle as
    /// unverified rather than as one that verified and then would not answer.
    case runtimeReplaced
    /// The command did not finish within its deadline and was ended.
    case timedOut
}
