import Darwin
import Foundation
import Synchronization

/// A direct child created by this owner, never a PID adopted from a later lookup.
///
/// The runtime must be the exclusive reaper of its children: no wildcard waits, SIGCHLD
/// handlers, or SA_NOCLDWAIT changes during this lifetime. Targeted observation, signaling,
/// and final reaping share one mutex. WNOWAIT keeps the child unreaped until this owner
/// disables all future signals and calls waitpid. No process-group signals are exposed yet.
/// A reaped direct child is NOT evidence that its descendants or private session are quiet.
final class OwnedChild: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidInvocation
        case systemCall(String, Int32)
        case waitAuthorityLost(Int32)
    }

    enum SignalResult: Equatable, Sendable {
        case delivered
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
        var reap: @Sendable (pid_t) -> Result<ProcessExit.Reason, Failure>
        var signal: @Sendable (pid_t, Int32) -> SignalResult

        static let live = Self(observe: { pid in
            var information = siginfo_t()
            guard waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT | WNOHANG) == 0 else {
                return errno == EINTR ? .running : .failed(errno)
            }
            return information.si_pid == pid ? .exited : .running
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
        var observer: Task<Void, Never>?
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
            refreshLocked(&state)
            if let completed = state.result {
                if case .success = completed { return .alreadyReaped }
                return .authorityLost
            }
            return calls.signal(processIdentifier, signal)
        }
        // Publish any terminal state and resume every waiter outside the lock.
        _ = poll()
        return result
    }

    private func startObservation() {
        // An unstructured owner task is intentional: the child must outlive cancellation or
        // release of every caller. It releases itself only on observed/reaped exit or loss
        // of wait authority. No blocking wait runs on the cooperative executor.
        let observer = Task { [self] in
            while !poll() { try? await Task.sleep(for: .milliseconds(10)) }
        }
        state.withLock { state in
            if state.result == nil { state.observer = observer }
        }
    }

    @discardableResult
    private func poll() -> Bool {
        let delivery = state.withLock { state -> (Result<ProcessExit.Reason, Failure>, [CheckedContinuation<Result<ProcessExit.Reason, Failure>, Never>])? in
            refreshLocked(&state)
            guard let result = state.result else { return nil }
            let waiters = state.waiters
            state.waiters.removeAll()
            return (result, waiters)
        }
        guard let delivery else { return false }
        for waiter in delivery.1 { waiter.resume(returning: delivery.0) }
        return true
    }

    private func refreshLocked(_ state: inout State) {
        guard state.result == nil else { return }
        switch calls.observe(processIdentifier) {
        case .running: return
        case .failed(let error): state.result = .failure(.waitAuthorityLost(error))
        case .exited: state.result = calls.reap(processIdentifier)
        }
        state.observer = nil
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
