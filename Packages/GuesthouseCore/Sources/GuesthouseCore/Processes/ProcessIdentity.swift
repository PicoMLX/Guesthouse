import Foundation

/// Everything recorded about a process the runtime launched, so that after a crash the same
/// process can be recognized again, and a reused PID cannot be mistaken for it
/// (MVP-PLAN.md §4, "Console and process ownership"; §10, Phase 1).
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    /// Kernel start time of the process. Two processes with the same PID never share it.
    public var startTime: Date
    public var executablePath: String
    /// A digest of the argument vector, so a different invocation of the same executable is
    /// not mistaken for ours. Never the arguments themselves; they can name paths.
    public var argumentsDigest: String
    public var vmName: String
    public var environmentID: EnvironmentID
    public var recordedAt: Date

    public init(pid: Int32, startTime: Date, executablePath: String, argumentsDigest: String, vmName: String, environmentID: EnvironmentID, recordedAt: Date) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
        self.argumentsDigest = argumentsDigest
        self.vmName = vmName
        self.environmentID = environmentID
        self.recordedAt = recordedAt
    }
}

/// The same observable facts about a process that is running right now. The runtime's
/// enumerator (issue #24) produces these; nothing here reads the process table.
public struct LiveProcess: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startTime: Date
    public var executablePath: String
    public var argumentsDigest: String

    public init(pid: Int32, startTime: Date, executablePath: String, argumentsDigest: String) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
        self.argumentsDigest = argumentsDigest
    }
}

/// The only three answers reconciliation can give. `uncertain` never means "safe to start".
public enum OwnershipVerdict: Hashable, Sendable {
    /// The recorded process is alive and is provably ours.
    case ownedRunning(LiveProcess)
    /// The recorded process is gone and nothing else claims the VM.
    case exited
    /// Something does not add up. Preserve the disk and ask for recovery; never launch a
    /// second instance and never kill a process that might belong to someone else.
    case uncertain(UncertaintyReason)

    public enum UncertaintyReason: Hashable, Sendable {
        /// A process with the recorded PID exists but its start time differs.
        case pidReusedByAnotherProcess
        /// Same PID and start time, but a different executable.
        case executableMismatch
        /// Same PID, start time, and executable, but different arguments.
        case argumentsMismatch
        /// No process matched, yet the VM's lock is still held.
        case lockHeldWithoutProcess
        /// More than one live process claims to match the record.
        case multipleCandidates
    }
}

/// Pure decision logic for "is the VM I recorded still mine?".
public enum ProcessReconciler {
    /// Start-time comparisons tolerate this much clock noise between the kernel's value at
    /// record time and at observation time.
    public static let startTimeTolerance: TimeInterval = 1.0

    /// - Parameters:
    ///   - recorded: what was journaled when the process was launched.
    ///   - observed: every live process that could plausibly be ours (usually all processes
    ///     whose executable is the Tart binary, plus whatever has the recorded PID).
    ///   - vmLockPresent: whether the VM directory's lock is currently held.
    public static func reconcile(
        recorded: ProcessIdentity,
        observed: [LiveProcess],
        vmLockPresent: Bool
    ) -> OwnershipVerdict {
        let samePID = observed.filter { $0.pid == recorded.pid }
        if samePID.count > 1 {
            return .uncertain(.multipleCandidates)
        }
        guard let candidate = samePID.first else {
            return vmLockPresent ? .uncertain(.lockHeldWithoutProcess) : .exited
        }
        guard abs(candidate.startTime.timeIntervalSince(recorded.startTime)) <= startTimeTolerance else {
            return .uncertain(.pidReusedByAnotherProcess)
        }
        guard candidate.executablePath == recorded.executablePath else {
            return .uncertain(.executableMismatch)
        }
        guard candidate.argumentsDigest == recorded.argumentsDigest else {
            return .uncertain(.argumentsMismatch)
        }
        return .ownedRunning(candidate)
    }
}
