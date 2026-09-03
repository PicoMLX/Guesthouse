import Foundation
import GuesthouseCore

/// Everything needed to launch one program: an executable URL and an argument array, never
/// a shell string (MVP-PLAN.md §3, "Process and trust boundaries"). The environment is
/// explicit; nothing is inherited from the service.
public struct ProcessInvocation: Hashable, Sendable {
    public enum StandardInput: Hashable, Sendable {
        case none
        case data(Data)
    }

    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL?
    public var standardInput: StandardInput
    /// Wall-clock limit for the whole run. SIGTERM at the deadline, SIGKILL after the grace period.
    public var timeout: Duration
    public var terminationGracePeriod: Duration
    /// Output kept per run, both streams together. Beyond it, further output is discarded and
    /// the exit reports `outputTruncated`, so a chatty child cannot exhaust the service.
    public var maximumOutputBytes: Int

    public static let defaultMaximumOutputBytes = 16 << 20

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        standardInput: StandardInput = .none,
        timeout: Duration = .seconds(60),
        terminationGracePeriod: Duration = .seconds(5),
        maximumOutputBytes: Int = ProcessInvocation.defaultMaximumOutputBytes
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.standardInput = standardInput
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.maximumOutputBytes = maximumOutputBytes
    }
}

/// One redacted line from the child's stdout or stderr.
public enum ProcessOutput: Hashable, Sendable {
    case stdout(RedactedLine)
    case stderr(RedactedLine)

    public var line: RedactedLine {
        switch self {
        case .stdout(let line), .stderr(let line): line
        }
    }
}

/// How the child ended.
public struct ProcessExit: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case status(Int32)
        case signal(Int32)
    }

    public let reason: Reason
    /// True when Guesthouse began ending the process because the timeout elapsed.
    public let timedOut: Bool
    /// True when Guesthouse began ending the process on request (cancellation).
    public let terminated: Bool
    /// True when the supplied standard input could not be delivered in full.
    public let standardInputFailed: Bool
    /// True when output was dropped: the per-run cap was reached, or the consumer fell too
    /// far behind the child.
    public let outputTruncated: Bool

    public init(reason: Reason, timedOut: Bool = false, terminated: Bool = false, standardInputFailed: Bool = false, outputTruncated: Bool = false) {
        self.reason = reason
        self.timedOut = timedOut
        self.terminated = terminated
        self.standardInputFailed = standardInputFailed
        self.outputTruncated = outputTruncated
    }

    /// Exit status zero, and nothing interrupted the run: an interrupted mutation that exits
    /// zero on SIGTERM is not a success.
    public var succeeded: Bool {
        guard case .status(0) = reason else { return false }
        return !timedOut && !terminated && !standardInputFailed
    }
}

/// Why a program could not be started, with what the user can do about it.
public enum ProcessLaunchError: Error, Hashable, Sendable, LocalizedError {
    case executableNotFound(String)
    /// The executable name and a sanitized launch diagnostic.
    case launchFailed(executable: String, reason: SanitizedText)

    public var userMessage: String {
        switch self {
        case .executableNotFound(let name):
            "The program \(GuesthouseError.sanitize(name)) is missing from the Guesthouse runtime. Repair reinstalls the tested runtime."
        case .launchFailed(let name, let reason):
            "The program \(GuesthouseError.sanitize(name)) could not be started (\(reason.value)). Repair reinstalls the tested runtime; if that does not help, try again after checking the runtime folder in Settings."
        }
    }

    /// In preference order. Never empty.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .executableNotFound: [.repair(.runtime), .cancel]
        case .launchFailed: [.repair(.runtime), .retry, .openSettings, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
}
