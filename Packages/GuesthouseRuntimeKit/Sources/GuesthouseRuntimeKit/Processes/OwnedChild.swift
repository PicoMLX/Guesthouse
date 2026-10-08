import Darwin
import Foundation
import Synchronization

/// Direct-child prerequisite retained from #108 for #21 (MVP-PLAN.md §§3–4).
/// A direct child created by this owner, never a PID adopted from a later lookup.
///
/// The runtime must be the exclusive reaper of its children: no wildcard waits, SIGCHLD
/// handlers, or SA_NOCLDWAIT changes during this lifetime. Signal decisions and final reaping
/// share one mutex. Only the blocking observer reaps, preserving the child's PID until its
/// WNOWAIT wait returns. No process-group signals are exposed yet.
/// A reaped direct child is NOT evidence that its descendants or private session are quiet.
final class OwnedChild: Sendable {
    enum ExitReason: Equatable, Sendable { case status(Int32), signal(Int32) }
    enum SystemCall: Sendable {
        case openDirectory, pinDirectory, validateDirectory, readSignalPolicy, exclusiveReaping
        case initializeActions, initializeAttributes, duplicateStdio, attachStdio, closeStdio
        case bindDirectory, closeDirectory, resetMask, resetDispositions, setFlags, spawn, invalidPID, allocateArguments
    }
    enum Failure: Error, Equatable, Sendable {
        case invalidInvocation
        case systemCall(SystemCall, Int32)
        case waitAuthorityLost(Int32)
    }

    enum SignalResult: Equatable, Sendable {
        case delivered
        case alreadyExited
        case alreadyReaped
        case authorityLost
        case refused(Int32)
    }

    enum Observation: Sendable {
        case running
        case exited
        case failed(Int32)
    }

    /// Injectable syscall boundary for focused authority-loss tests. Only spawn constructs
    /// an owner; production callers cannot turn an arbitrary PID into signal authority.
    struct SystemCalls: Sendable {
        var observe: @Sendable (pid_t) -> Observation
        var waitForExit: @Sendable (pid_t) -> Result<Void, Failure>
        var reap: @Sendable (pid_t) -> Result<ExitReason, Failure>
        var signal: @Sendable (pid_t, Int32) -> SignalResult
        var birth: @Sendable (pid_t) -> LiveProcessProbe.Identity = LiveProcessProbe.Reads.readOwnedChildIdentity

        static let live = Self(observe: { pid in
            var information = siginfo_t()
            guard waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT | WNOHANG) == 0 else {
                return errno == EINTR ? .running : .failed(errno)
            }
            return information.si_pid == pid ? .exited : .running
        }, waitForExit: { pid in
            var information = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT) }
            while result == -1 && errno == EINTR
            guard result == 0 else { return .failure(.waitAuthorityLost(errno)) }
            guard information.si_pid == pid else { return .failure(.waitAuthorityLost(ECHILD)) }
            return .success(())
        }, reap: { pid in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, WNOHANG) } while result == -1 && errno == EINTR
            guard result == pid else { return .failure(.waitAuthorityLost(result == 0 ? EAGAIN : errno)) }
            // Darwin's wait status layout; WIFEXITED/WTERMSIG function-like macros do not
            // import into Swift. A WEXITED observation cannot produce a stopped status.
            let signal = status & 0x7f
            return .success(signal == 0 ? .status((status >> 8) & 0xff) : .signal(signal))
        }, signal: { pid, signal in
            kill(pid, signal) == 0 ? .delivered : .refused(errno)
        })
    }

    private struct State {
        var result: Result<ExitReason, Failure>?
        var forkObservation: OwnedChildForkObservation.Result = .unproven
        var waiters: [CheckedContinuation<Result<ExitReason, Failure>, Never>] = []
    }

    /// Caller-supplied correlation for a durable intent, not transferable signal authority.
    let runID: UUID
    let processIdentifier: pid_t
    /// Kernel birth plus the actual spawn inputs, not a later live observation or authority
    /// to adopt/signal a PID after restart. No arguments or environment values are persisted.
    struct LaunchIdentity: Codable, Equatable, Sendable {
        let runID: UUID
        let pid: Int32
        let startTime: Date
        let executablePath: String
        let argumentsDigest: String
        var isConsistent: Bool {
            pid > 0 && startTime.timeIntervalSince1970.isFinite && startTime.timeIntervalSince1970 > 0
                && executablePath.hasPrefix("/") && !executablePath.utf8.contains(0)
                && argumentsDigest.hasPrefix("sha256:") && argumentsDigest.utf8.count == 71
                && argumentsDigest.dropFirst(7).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        fileprivate init(runID: UUID, pid: Int32, startTime: Date, executable: URL, arguments: [String]) {
            self.runID = runID; self.pid = pid; self.startTime = startTime
            executablePath = executable.path; argumentsDigest = LiveProcessProbe.digest(arguments)
        }
    }
    let launchIdentity: LaunchIdentity?
    private let calls: SystemCalls
    private let forks: OwnedChildForkObservation?
    private let state = Mutex(State())

    private init(runID: UUID, processIdentifier: pid_t, calls: SystemCalls, identity: LaunchIdentity?, forks: OwnedChildForkObservation?) {
        self.runID = runID
        self.processIdentifier = processIdentifier
        self.calls = calls
        launchIdentity = identity
        self.forks = forks
    }

    /// Kernel history of this exact live-owned launch, not a saved/restart capability. Only
    /// successful observation AND reaping can publish exitedWithoutFork. Other launches and
    /// any observed fork remain unproven for descendants. StateStore settlement is not wired.
    var forkObservation: OwnedChildForkObservation.Result { state.withLock { $0.forkObservation } }

    /// Completion means only that this exact direct child has been observed and reaped.
    /// This wait deliberately ignores task cancellation. A caller can separately request a
    /// signal, but cancellation must not abandon a child or its one reaper.
    func waitForReapedExit() async -> Result<ExitReason, Failure> {
        await withCheckedContinuation { continuation in
            let completed = state.withLock { state -> Result<ExitReason, Failure>? in
                if let result = state.result { return result }
                state.waiters.append(continuation)
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    /// Never signals after reaping or a wait error. A delivered signal is not an exit.
    @discardableResult
    func signal(_ signal: Int32) -> SignalResult {
        // Observe before signaling, including ECHILD, under the same lock as the syscall.
        // The exclusive-reaper contract prevents PID reuse between these operations.
        let result = state.withLock { state -> SignalResult in
            if let completed = state.result {
                if case .success = completed { return .alreadyReaped }
                return .authorityLost
            }
            switch calls.observe(processIdentifier) {
            case .running: return calls.signal(processIdentifier, signal)
            case .exited: return .alreadyExited
            case .failed(let error):
                state.result = .failure(.waitAuthorityLost(error))
                return .authorityLost
            }
        }
        // Publish any terminal state and resume every waiter outside the lock.
        publishCompletion()
        return result
    }

    private func startObservation() {
        // One noncooperative dispatch waiter retains ownership through cancellation or
        // release of every caller, without periodic wakeups. The wait is outside the mutex
        // so signals remain possible. Only this callback may reap: an earlier reap could let
        // the blocking wait start or resume against a different child that reused the PID.
        DispatchQueue(label: "GuesthouseRuntimeKit.OwnedChild.exit", qos: .utility).async { [self] in
            let observed = calls.waitForExit(processIdentifier)
            state.withLock { state in
                guard state.result == nil else { return }
                switch observed {
                case .success:
                    let history = forks?.afterObservedExit() ?? .unproven
                    let reaped = calls.reap(processIdentifier)
                    state.result = reaped
                    if case .success = reaped { state.forkObservation = history }
                case .failure(let failure): state.result = .failure(failure)
                }
            }
            publishCompletion()
        }
    }

    private func publishCompletion() {
        let delivery = state.withLock { state -> (Result<ExitReason, Failure>, [CheckedContinuation<Result<ExitReason, Failure>, Never>])? in
            guard let result = state.result else { return nil }
            let waiters = state.waiters
            state.waiters.removeAll()
            return (result, waiters)
        }
        guard let delivery else { return }
        for waiter in delivery.1 { waiter.resume(returning: delivery.0) }
    }

    /// Stdio descriptors are borrowed only until spawn returns; spawn duplicates and closes
    /// its own copies. The working-directory capability remains alive through addfchdir.
    static func spawn(
        runID: UUID = UUID(),
        observingForks: Bool = false,
        executable: URL, arguments: [String] = [], environment: [String: String] = [:],
        workingDirectory: PinnedWorkingDirectory? = nil,
        standardInput: Int32, standardOutput: Int32, standardError: Int32,
        calls: SystemCalls = .live
    ) throws -> OwnedChild {
        let pid = try OwnedChildSpawn.launch(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory,
            descriptors: [standardInput, standardOutput, standardError], startSuspended: observingForks
        )
        // Capture before starting the reaper, including a child that exited during spawn.
        // If the kernel cannot establish birth, retain the child/reaper but publish no identity.
        let identity: LaunchIdentity?
        if case .present(let birth) = calls.birth(pid) {
            let candidate = LaunchIdentity(runID: runID, pid: pid, startTime: birth,
                                           executable: executable, arguments: arguments)
            identity = candidate.isConsistent ? candidate : nil
        } else { identity = nil }
        let forks = observingForks && identity != nil ? OwnedChildForkObservation(pid: pid) : nil
        let child = OwnedChild(runID: runID, processIdentifier: pid, calls: calls, identity: identity, forks: forks)
        if observingForks {
            // Never enter user code without a complete observation boundary. Retain actual
            // child/reaper on any failure; signal delivery is not cleanup proof.
            // This owner has not escaped or started its reaper: the exclusive direct-child
            // contract holds its PID. waitid can report the initial suspended stop on Darwin,
            // so do not use the ordinary running/exit probe to resume this new child.
            if forks == nil || calls.signal(pid, SIGCONT) != .delivered { _ = calls.signal(pid, SIGKILL) }
        }
        child.startObservation()
        return child
    }
}
