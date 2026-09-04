import Foundation
import GuesthouseCore

/// Runs the verified Tart bundle with `TART_HOME` pinned to the VM store.
///
/// Only `version()` exists here; inventory, IP discovery, and lifecycle arrive with #25.
public struct TartBackend: Sendable {
    public let bundle: TartBundle
    public let storage: RuntimeStorage
    public let runner: any ProcessRunning
    /// What the executable was when the service verified it. Every launch checks that the
    /// file has not been replaced since, so an unsigned substitute cannot be run.
    public let verifiedExecutable: TartBundle.ExecutableIdentity?

    public init(bundle: TartBundle, storage: RuntimeStorage, runner: any ProcessRunning, verifiedExecutable: TartBundle.ExecutableIdentity? = nil) {
        self.bundle = bundle
        self.storage = storage
        self.runner = runner
        self.verifiedExecutable = verifiedExecutable
    }

    /// Refuses to launch when the executable is not the file that passed verification.
    func requireVerifiedExecutable() throws {
        guard let verifiedExecutable else { return }
        guard bundle.executableIdentity == verifiedExecutable else {
            throw TartInvocationError.failed(.unknown(RedactedLine(literal: "the runtime was replaced after it was verified")))
        }
    }

    /// Launches the verified executable. macOS has no `fexecve`, so a process cannot be
    /// started from an open descriptor: the runner opens the path. The window that leaves is
    /// closed from the other side instead. The identity is checked again the moment the child
    /// exists, and a process started from anything but the verified file is ended before it
    /// is spoken to, so a substitute never receives a request or reaches a VM.
    func launch(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        try requireVerifiedExecutable()
        let run = try await runner.run(invocation)
        do {
            try requireVerifiedExecutable()
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
        let run = try await launch(ProcessInvocation(
            executable: bundle.executable,
            arguments: ["--version"],
            environment: storage.environmentForTart(),
            timeout: .seconds(15)
        ))
        var stdout: [String] = []
        var stderr: [String] = []
        var truncatedRecords = false
        for await line in run.output {
            // A command whose output is parsed is bounded by record count as well as by the
            // runner's byte cap: empty records cost no bytes but still cost memory.
            guard stdout.count + stderr.count < Self.maximumCapturedRecords else {
                truncatedRecords = true
                break
            }
            switch line {
            case .stdout(let text): stdout.append(text.text)
            case .stderr(let text): stderr.append(text.text)
            }
        }
        let exit = await run.exit()
        guard exit.succeeded else {
            throw TartInvocationError.failed(TartErrorClassifier.classify(stderr: stderr.joined(separator: "\n"), exitStatus: exitStatus(exit)))
        }
        // A truncated capture is not a complete answer: the parser must see all of stdout
        // before a version is accepted as the runtime's own.
        guard !exit.outputTruncated, !truncatedRecords else { throw TartInvocationError.unparseableOutput }
        guard let version = TartVersion(parsing: stdout.joined(separator: "\n")) else {
            throw TartInvocationError.unparseableOutput
        }
        return version
    }

    private func exitStatus(_ exit: ProcessExit) -> Int32 {
        switch exit.reason {
        case .status(let status): status
        case .signal(let signal): 128 + signal
        }
    }
}

public enum TartInvocationError: Error, Hashable, Sendable {
    case failed(TartFailure)
    case unparseableOutput
}
