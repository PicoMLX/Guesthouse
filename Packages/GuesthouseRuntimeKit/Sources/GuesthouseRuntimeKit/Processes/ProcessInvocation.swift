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

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        standardInput: StandardInput = .none,
        timeout: Duration = .seconds(60),
        terminationGracePeriod: Duration = .seconds(5)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.standardInput = standardInput
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
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
    /// True when Guesthouse ended the process because the timeout elapsed.
    public let timedOut: Bool
    /// True when Guesthouse ended the process on request (cancellation).
    public let terminated: Bool

    public init(reason: Reason, timedOut: Bool = false, terminated: Bool = false) {
        self.reason = reason
        self.timedOut = timedOut
        self.terminated = terminated
    }

    public var succeeded: Bool {
        if case .status(0) = reason { return true }
        return false
    }
}

public enum ProcessLaunchError: Error, Hashable, Sendable {
    case executableNotFound(String)
    case launchFailed(String)
}
