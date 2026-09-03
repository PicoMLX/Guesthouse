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

    /// A record whose VM name is not the environment's own name describes some other VM;
    /// ownership is never granted on it.
    public var isConsistent: Bool { vmName == environmentID.tartVMName }

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
    /// The VM the process claims to run (`tart run <name> …`), parsed and validated by the
    /// enumerator; `nil` when the arguments name no VM.
    public var claimedVMName: String?

    public init(pid: Int32, startTime: Date, executablePath: String, argumentsDigest: String, claimedVMName: String? = nil) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
        self.argumentsDigest = argumentsDigest
        self.claimedVMName = claimedVMName
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
        /// The recorded process is gone, but another process claims the same VM (the same
        /// invocation, or `tart run` naming the VM); it may be acquiring the lock right now.
        case anotherProcessClaimsVM
        /// The record names a VM that is not the environment's own.
        case recordInconsistent
        /// The live process does not name the recorded virtual machine, so it cannot be
        /// proven to be this environment's VM.
        case vmNameUnconfirmed
        /// The VM appears to be running but no launch was ever recorded for it: the service
        /// was interrupted between spawning Tart and persisting the identity, or something
        /// else started the VM.
        case unrecordedLaunch
        /// The VM inventory could not be read, so nothing about the VM's lock is known.
        case inventoryUnavailable
        /// The recorded process exists but could not be read from the process table (for
        /// example it now belongs to another user), so it cannot be matched or ruled out.
        case processUnobservable
    }
}

/// Pure decision logic for "is the VM I recorded still mine?".
public enum ProcessReconciler {
    /// The kernel's start time is an identity, stored losslessly and compared exactly; a
    /// process with the same PID and a different start time is another process.

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
        guard recorded.isConsistent else { return .uncertain(.recordInconsistent) }
        let samePID = observed.filter { $0.pid == recorded.pid }
        if samePID.count > 1 {
            return .uncertain(.multipleCandidates)
        }
        // Any other live process that claims this VM, by the same invocation or by naming it,
        // leaves ownership unproven: the lock evidence does not say which process holds it.
        let claimants = observed.filter { $0.pid != recorded.pid && ($0.argumentsDigest == recorded.argumentsDigest || $0.claimedVMName == recorded.vmName) }
        guard let candidate = samePID.first else {
            if vmLockPresent { return .uncertain(.lockHeldWithoutProcess) }
            // A competing process may be about to take the lock; nothing is safe to start.
            return claimants.isEmpty ? .exited : .uncertain(.anotherProcessClaimsVM)
        }
        guard candidate.startTime == recorded.startTime else {
            return .uncertain(.pidReusedByAnotherProcess)
        }
        guard candidate.executablePath == recorded.executablePath else {
            return .uncertain(.executableMismatch)
        }
        guard candidate.argumentsDigest == recorded.argumentsDigest else {
            return .uncertain(.argumentsMismatch)
        }
        // The process must name the recorded VM itself. A record that paired this environment
        // with another VM's invocation, or a process whose arguments cannot be read as a VM
        // launch, never grants ownership.
        guard candidate.claimedVMName == recorded.vmName else {
            return .uncertain(.vmNameUnconfirmed)
        }
        guard claimants.isEmpty else {
            return .uncertain(.anotherProcessClaimsVM)
        }
        return .ownedRunning(candidate)
    }
}
