import Foundation
import GuesthouseCore

public struct LumeProbeResult: Hashable, Sendable {
    public let version: SemanticVersion
    public let capabilities: RuntimeVersionInfo.LumeCapabilities
}

public enum LumeInvocationError: Error, Hashable, Sendable {
    case storageMismatch
    case bundleChanged
    case failed(status: Int32)
    case timedOut
    case outputTruncated
    case unparseableOutput
    case versionMismatch(found: SemanticVersion, required: SemanticVersion)

    public var userMessage: String {
        switch self {
        case .storageMismatch:
            "The verified Lume runtime does not belong to the selected Guesthouse storage."
        case .bundleChanged:
            "The installed Lume runtime changed after it was verified."
        case .failed:
            "Lume exited before Guesthouse could inspect its capabilities."
        case .timedOut:
            "Lume did not answer the capability probe before its safety timeout."
        case .outputTruncated:
            "Lume returned more capability output than Guesthouse can safely inspect."
        case .unparseableOutput:
            "Lume returned capability information Guesthouse does not understand."
        case .versionMismatch:
            "The running Lume version does not match the verified release."
        }
    }

    public var recoveryActions: [RecoveryAction] { [.repair(.runtime), .cancel] }

    public var errorDescription: String? { userMessage }
}

extension LumeInvocationError: LocalizedError {}

/// Non-VM-mutating interrogation of one verified Lume executable. Lume may still create its
/// own config, so XDG and temporary state are redirected into private runtime storage. VM
/// inventory and mutating operations remain out of scope until the hardware gate.
public struct LumeBackend: Sendable {
    private let bundle: VerifiedLumeBundle
    private let storage: RuntimeStorage
    private let runner: any ProcessRunning
    private let verifyBeforeLaunch: @Sendable () throws -> URL

    public init(bundle: VerifiedLumeBundle, storage: RuntimeStorage, runner: any ProcessRunning) throws {
        guard Self.bundlePath(bundle, belongsTo: storage) else {
            throw LumeInvocationError.storageMismatch
        }
        guard let currentIdentity = RuntimeStorage.fileIdentity(of: LumeBundle.expectedLocation(in: storage)),
              bundle.fileIdentity == currentIdentity
        else {
            throw LumeInvocationError.bundleChanged
        }
        self.init(bundle: bundle, storage: storage, runner: runner) {
            try Self.reverify(bundle, in: storage)
        }
    }

    init(
        bundle: VerifiedLumeBundle,
        storage: RuntimeStorage,
        runner: any ProcessRunning,
        verifyBeforeLaunch: @escaping @Sendable () throws -> URL
    ) {
        self.bundle = bundle
        self.storage = storage
        self.runner = runner
        self.verifyBeforeLaunch = verifyBeforeLaunch
    }

    private static func bundlePath(_ bundle: VerifiedLumeBundle, belongsTo storage: RuntimeStorage) -> Bool {
        let expectedURL = LumeBundle.expectedLocation(in: storage)
        return bundle.bundle.url.standardizedFileURL.path == expectedURL.standardizedFileURL.path
    }

    /// Repeats discovery as well as signature verification at the launch boundary. Discovery
    /// rechecks every app-managed ancestor, so replacing `runtime/` or the release directory with
    /// a link cannot redirect a still-valid bundle token outside the leased storage tree.
    private static func reverify(_ bundle: VerifiedLumeBundle, in storage: RuntimeStorage) throws -> URL {
        try relocateForLaunch(bundle, in: storage).verify().executable
    }

    /// Separated from signature verification so the managed-path recheck has focused regression
    /// coverage without weakening or substituting the production signature gate.
    static func relocateForLaunch(_ bundle: VerifiedLumeBundle, in storage: RuntimeStorage) throws -> LumeBundle {
        guard let current = LumeBundle.locate(in: storage),
              RuntimeStorage.fileIdentity(of: current.url) == bundle.fileIdentity
        else { throw LumeInvocationError.bundleChanged }
        return current
    }

    public func probe() async throws -> LumeProbeResult {
        try await LumeRuntimeCoordinator.shared.withExclusiveAccess(for: storage) {
            try await probeExclusively()
        }
    }

    private func probeExclusively() async throws -> LumeProbeResult {
        let versionOutput = try await capture(["--version"], timeout: .seconds(5))
        guard let version = SemanticVersion(versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LumeInvocationError.unparseableOutput
        }
        guard version == bundle.version else {
            throw LumeInvocationError.versionMismatch(found: version, required: bundle.version)
        }
        // Bare `run --help` enters AppKit in 0.5.3. `--detach` makes help safe to inspect.
        // These remain serial within the coordinator's whole-probe lease because Lume can
        // initialize shared XDG configuration even for introspection.
        let createHelp = try await capture(["create", "--help"], timeout: .seconds(5))
        let runHelp = try await capture(["run", "--detach", "--help"], timeout: .seconds(5))
        let attachHelp = try await capture(["attach", "--help"], timeout: .seconds(5))
        return LumeProbeResult(
            version: version,
            capabilities: Self.capabilities(createHelp: createHelp, runHelp: runHelp, attachHelp: attachHelp)
        )
    }

    static func capabilities(createHelp: String, runHelp: String, attachHelp: String) -> RuntimeVersionInfo.LumeCapabilities {
        RuntimeVersionInfo.LumeCapabilities(
            unattendedTahoe: hasOption("--unattended", in: createHelp) && hasWord("tahoe", in: createHelp),
            createRunAttachStorage: hasOption("--storage", in: createHelp) && hasOption("--storage", in: runHelp) && hasOption("--storage", in: attachHelp),
            detachedRun: hasOption("--detach", in: runHelp),
            nativeAttach: hasOption("--display", in: attachHelp) && hasWord("native", in: attachHelp),
            // This adapter accepts exactly 0.5.3. That release cannot disable its always-on
            // private-API VNC server; keep the security result pinned instead of inferring it
            // from prose or similarly named help options.
            vncCanBeDisabled: false
        )
    }

    private static func hasOption(_ option: String, in help: String) -> Bool {
        help.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).contains(Substring(option))
    }

    private static func hasWord(_ word: String, in help: String) -> Bool {
        help.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    private func capture(_ arguments: [String], timeout: Duration) async throws -> String {
        try Task.checkCancellation()
        // The token proves an earlier check, but the app could have been updated or replaced
        // since then. Revalidate immediately before every launch and fail closed. Guesthouse's
        // threat boundary excludes a hostile process already running as the host user; the
        // eventual installer must use `LumeRuntimeCoordinator.shared.withExclusiveAccess(for:)`
        // while atomically placing the new bundle in this private directory.
        let executable: URL
        do { executable = try verifyBeforeLaunch() }
        catch { throw LumeInvocationError.bundleChanged }
        try Task.checkCancellation()
        let run: ProcessRun
        do {
            run = try await runner.run(ProcessInvocation(
                executable: executable,
                arguments: arguments,
                environment: storage.environmentForLume(),
                currentDirectory: storage.url(for: .staging),
                timeout: timeout,
                maximumOutputBytes: 1 << 20
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A path swap can surface as a launch error in the narrow interval after the first
            // check. Reverify before preserving the earlier `verified` verdict.
            do { _ = try verifyBeforeLaunch() }
            catch { throw LumeInvocationError.bundleChanged }
            throw error
        }
        let (stdout, exit) = await withTaskCancellationHandler {
            var stdout: [String] = []
            for await line in run.output {
                if case .stdout(let text) = line { stdout.append(text.text) }
            }
            return (stdout.joined(separator: "\n"), await run.exit())
        } onCancel: {
            run.terminate(gracePeriod: .seconds(1))
        }
        if Task.isCancelled { throw CancellationError() }
        if exit.timedOut { throw LumeInvocationError.timedOut }
        if exit.outputTruncated { throw LumeInvocationError.outputTruncated }
        guard exit.succeeded else { throw LumeInvocationError.failed(status: Self.exitStatus(exit)) }
        return stdout
    }

    private static func exitStatus(_ exit: ProcessExit) -> Int32 {
        switch exit.reason {
        case .status(let status): status
        case .signal(let signal): 128 + signal
        }
    }
}
