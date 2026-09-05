import Darwin
import Foundation
import Synchronization

/// A direct child created by this owner, never a PID adopted from a later lookup.
///
/// The runtime must be the exclusive reaper of its children: no wildcard waits, SIGCHLD
/// handlers, or SA_NOCLDWAIT changes during this lifetime. Signal decisions and final reaping
/// share one mutex. Only the blocking observer reaps, preserving the child's PID until its
/// WNOWAIT wait returns. No process-group signals are exposed yet.
/// A reaped direct child is NOT evidence that its descendants or private session are quiet.
final class OwnedChild: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidInvocation
        case systemCall(String, Int32)
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
        var reap: @Sendable (pid_t) -> Result<ProcessExit.Reason, Failure>
        var signal: @Sendable (pid_t, Int32) -> SignalResult

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
        var result: Result<ProcessExit.Reason, Failure>?
        var waiters: [CheckedContinuation<Result<ProcessExit.Reason, Failure>, Never>] = []
    }

    /// Caller-supplied correlation for a durable intent, not transferable signal authority.
    let runID: UUID
    let processIdentifier: pid_t
    private let calls: SystemCalls
    private let state = Mutex(State())

    private init(runID: UUID, processIdentifier: pid_t, calls: SystemCalls) {
        self.runID = runID
        self.processIdentifier = processIdentifier
        self.calls = calls
    }

    /// Completion means only that this exact direct child has been observed and reaped.
    /// This wait deliberately ignores task cancellation. A caller can separately request a
    /// signal, but cancellation must not abandon a child or its one reaper.
    func waitForReapedExit() async -> Result<ProcessExit.Reason, Failure> {
        await withCheckedContinuation { continuation in
            let completed = state.withLock { state -> Result<ProcessExit.Reason, Failure>? in
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
                case .success: state.result = calls.reap(processIdentifier)
                case .failure(let failure): state.result = .failure(failure)
                }
            }
            publishCompletion()
        }
    }

    private func publishCompletion() {
        let delivery = state.withLock { state -> (Result<ProcessExit.Reason, Failure>, [CheckedContinuation<Result<ProcessExit.Reason, Failure>, Never>])? in
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
        executable: URL, arguments: [String] = [], environment: [String: String] = [:],
        workingDirectory: PinnedWorkingDirectory? = nil,
        standardInput: Int32, standardOutput: Int32, standardError: Int32,
        calls: SystemCalls = .live
    ) throws -> OwnedChild {
        let pid = try OwnedChildSpawn.launch(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory,
            descriptors: [standardInput, standardOutput, standardError]
        )
        let child = OwnedChild(runID: runID, processIdentifier: pid, calls: calls)
        child.startObservation()
        return child
    }
}
