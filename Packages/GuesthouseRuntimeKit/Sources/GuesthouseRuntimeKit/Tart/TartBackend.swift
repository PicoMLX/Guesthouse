import Foundation
import GuesthouseCore

/// Runs the verified Tart bundle with `TART_HOME` pinned to the VM store.
///
/// Only `version()` exists here; inventory, IP discovery, and lifecycle arrive with #25.
public struct TartBackend: Sendable {
    public let bundle: TartBundle
    public let storage: RuntimeStorage
    public let runner: any ProcessRunning

    public init(bundle: TartBundle, storage: RuntimeStorage, runner: any ProcessRunning) {
        self.bundle = bundle
        self.storage = storage
        self.runner = runner
    }

    /// `tart --version`, parsed strictly. Anything unparseable is reported as a failure, never
    /// guessed.
    public func version() async throws -> TartVersion {
        let run = try await runner.run(ProcessInvocation(
            executable: bundle.executable,
            arguments: ["--version"],
            environment: storage.environmentForTart(),
            timeout: .seconds(15)
        ))
        var stdout: [String] = []
        var stderr: [String] = []
        for await line in run.output {
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
        guard !exit.outputTruncated else { throw TartInvocationError.unparseableOutput }
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
