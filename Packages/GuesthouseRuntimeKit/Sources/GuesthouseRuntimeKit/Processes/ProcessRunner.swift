import Darwin
import Foundation
import GuesthouseCore

/// Anything that can run a `ProcessInvocation`. `ProcessRunner` is the real one; tests and
/// the Tart backend's tests substitute a fake.
public protocol ProcessRunning: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessRun
}

/// A running or finished child process: its redacted output and its exit.
///
/// A run keeps itself alive until the child has exited, so a caller that stops listening
/// cannot orphan the child: the timeout and the kill after the grace period still fire.
public final class ProcessRun: @unchecked Sendable {
    /// Line-buffered stdout and stderr, each line redacted before it leaves this type.
    public let output: AsyncStream<ProcessOutput>

    private let lock = NSLock()
    private let process: Process
    private let outputContinuation: AsyncStream<ProcessOutput>.Continuation
    private var exitResult: ProcessExit?
    private var exitWaiters: [CheckedContinuation<ProcessExit, Never>] = []
    private var timedOut = false
    private var terminationRequested = false
    private var standardInputFailed = false
    private var outputTruncated = false
    /// Set under the same lock that reads it, so two overlapping requests cannot each start
    /// their own escalation of the same process graph.
    private var terminating = false
    /// When SIGKILL is due, and which escalation owns that deadline: an earlier deadline
    /// supersedes the one already waiting, and the superseded task does nothing.
    private var killDeadline: ContinuousClock.Instant?
    private var killGeneration = 0
    private var capturedDescendants: [pid_t: Date] = [:]
    /// The child's start time, read at launch. A PID the kernel reused after the child exited
    /// is not the child, and is never signaled.
    private var childStart: Date?
    private var timeoutTask: Task<Void, Never>?
    private var standardInputChannel: DispatchIO?
    /// Self-reference held from launch until `finish`, so the run outlives its callers.
    private var retainedWhileRunning: ProcessRun?

    init(process: Process, output: AsyncStream<ProcessOutput>, continuation: AsyncStream<ProcessOutput>.Continuation) {
        self.process = process
        self.output = output
        self.outputContinuation = continuation
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// When SIGKILL falls due for whatever has not stopped yet, and `nil` once nothing is
    /// pending. It outlives the child's own exit: a descendant that is still shutting down
    /// keeps the grace period the caller asked for.
    var escalationDeadline: ContinuousClock.Instant? { lock.withLock { killDeadline } }

    /// Waits for the child to end.
    public func exit() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let exitResult {
                    continuation.resume(returning: exitResult)
                } else {
                    exitWaiters.append(continuation)
                }
            }
        }
    }

    /// Asks the child to stop: SIGTERM now, SIGKILL after the grace period if it is still alive.
    public func terminate(gracePeriod: Duration) {
        stop(gracePeriod: gracePeriod, becauseOfTimeout: false)
    }

    func timeOut(gracePeriod: Duration) {
        stop(gracePeriod: gracePeriod, becauseOfTimeout: true)
    }

    func retainWhileRunning() {
        lock.withLock { retainedWhileRunning = self }
    }

    /// Reads the child's identity right after launch, while the PID is certainly still its own.
    func recordChildIdentity() {
        let start = Self.startTime(of: process.processIdentifier)
        lock.withLock { childStart = start }
    }

    func markStandardInputFailed() {
        lock.withLock { standardInputFailed = true }
    }

    /// The deadline task is canceled with the run, so a short command does not keep its
    /// process graph alive until a long timeout would have fired.
    func armTimeout(_ task: Task<Void, Never>) {
        let alreadyFinished: Bool = lock.withLock {
            timeoutTask = task
            return exitResult != nil
        }
        if alreadyFinished { task.cancel() }
    }

    func attachStandardInput(_ channel: DispatchIO) {
        lock.withLock { standardInputChannel = channel }
    }

    /// Stops a delivery nobody is reading: the channel's pending write ends with
    /// `ECANCELED`, and the descriptor is closed, so no writer stays blocked forever.
    func abandonStandardInput() {
        let channel: DispatchIO? = lock.withLock { standardInputChannel }
        channel?.close(flags: .stop)
    }

    func markOutputTruncated() {
        lock.withLock { outputTruncated = true }
    }

    /// What one request has to do about a termination that may already be under way.
    private enum TerminationStep {
        case ignore
        case begin
        case shorten
    }

    /// Records the interruption only when termination really starts: a child that exited on
    /// its own moments earlier is never reported as interrupted.
    ///
    /// - Returns: whether this call is the one that began the termination.
    @discardableResult
    func stop(gracePeriod: Duration, becauseOfTimeout: Bool) -> Bool {
        let deadline = ContinuousClock.now + gracePeriod
        let (step, generation): (TerminationStep, Int) = lock.withLock {
            guard exitResult == nil, process.isRunning else { return (.ignore, 0) }
            if becauseOfTimeout { timedOut = true } else { terminationRequested = true }
            // A request that would escalate no earlier than the one already waiting changes
            // nothing; an earlier one takes over, so a caller asking for a long grace period
            // cannot stretch the invocation past its own deadline.
            if terminating, let current = killDeadline, deadline >= current { return (.ignore, 0) }
            let step: TerminationStep = terminating ? .shorten : .begin
            terminating = true
            killDeadline = deadline
            killGeneration += 1
            return (step, killGeneration)
        }
        switch step {
        case .ignore:
            return false
        case .begin:
            beginTermination()
            escalate(after: gracePeriod, generation: generation)
            return true
        case .shorten:
            escalate(after: gracePeriod, generation: generation)
            return false
        }
    }

    /// SIGTERM for the child and for every helper it had forked, so a timeout cannot leave a
    /// descendant modifying the host or the VM after the exit is reported. Each helper is
    /// captured with its start time and signaled only while it is still that process.
    private func beginTermination() {
        var captured: [pid_t: Date] = [:]
        for child in Self.descendants(of: process.processIdentifier) {
            captured[child] = Self.startTime(of: child)
        }
        lock.withLock { capturedDescendants = captured }
        process.terminate()
        for (child, start) in captured { Self.signalIfUnchanged(SIGTERM, to: child, startedAt: start) }
    }

    /// SIGKILL for whatever ignored SIGTERM, when the grace period ends. Deliberately not tied
    /// to the child's own exit: a descendant still cleaning up keeps the whole grace period
    /// even when its parent exits at once.
    private func escalate(after gracePeriod: Duration, generation: Int) {
        let pid = process.processIdentifier
        Task { [self] in
            try? await Task.sleep(for: gracePeriod)
            let state: (captured: [pid_t: Date], child: Date?)? = lock.withLock {
                // A later request with an earlier deadline has taken this over.
                guard killGeneration == generation else { return nil }
                killDeadline = nil
                return (capturedDescendants, childStart)
            }
            guard let (captured, child) = state else { return }
            for (descendant, start) in captured { Self.signalIfUnchanged(SIGKILL, to: descendant, startedAt: start) }
            // Helpers first seen now are captured with their identity as well, and only while
            // the child is still ours: once its PID belongs to somebody else, the processes
            // below it are strangers.
            if let child, Self.startTime(of: pid) == child {
                var late: [pid_t: Date] = [:]
                for descendant in Self.descendants(of: pid) where captured[descendant] == nil {
                    late[descendant] = Self.startTime(of: descendant)
                }
                for (descendant, start) in late { Self.signalIfUnchanged(SIGKILL, to: descendant, startedAt: start) }
            }
            Self.signalIfUnchanged(SIGKILL, to: pid, startedAt: child)
        }
    }

    func finish(with reason: ProcessExit.Reason) {
        // The handler captured this run; releasing it breaks the run/process cycle.
        process.terminationHandler = nil
        // The escalation task outlives this: descendants may still be cleaning up on the
        // SIGTERM they were sent, and they keep the grace period the caller asked for.
        let (waiters, exit): ([CheckedContinuation<ProcessExit, Never>], ProcessExit) = lock.withLock {
            timeoutTask?.cancel()
            timeoutTask = nil
            let exit = ProcessExit(reason: reason, timedOut: timedOut, terminated: terminationRequested, standardInputFailed: standardInputFailed, outputTruncated: outputTruncated)
            exitResult = exit
            let pending = exitWaiters
            exitWaiters.removeAll()
            retainedWhileRunning = nil
            return (pending, exit)
        }
        outputContinuation.finish()
        for waiter in waiters { waiter.resume(returning: exit) }
    }

    /// Signals `pid` only while it is still the process whose start time was captured. A PID
    /// the kernel handed to somebody else after that process exited is left alone, whatever
    /// the delay between capturing it and signaling it (MVP-PLAN.md §4).
    @discardableResult
    static func signalIfUnchanged(_ signal: Int32, to pid: pid_t, startedAt start: Date?) -> Bool {
        guard let start, startTime(of: pid) == start else { return false }
        return kill(pid, signal) == 0
    }

    /// The kernel's start time for `pid`, the identity that tells a reused PID from the
    /// process that was captured; `nil` when the process cannot be read.
    static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Every live descendant of `pid`, deepest last. `proc_listchildpids` reports counts of
    /// pids, not bytes.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [pid]
        while let parent = queue.popLast() {
            let expected = proc_listchildpids(parent, nil, 0)
            guard expected > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: Int(expected) + 16)
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                proc_listchildpids(parent, pointer.baseAddress, Int32(pointer.count * MemoryLayout<pid_t>.size))
            }
            let children = buffer.prefix(max(0, Int(count))).filter { $0 > 0 }
            found.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return found
    }
}

/// Launches programs with an executable URL and argument array, streams their output through
/// the redactor, enforces a timeout, and never involves a shell.
public actor ProcessRunner: ProcessRunning {
    /// Standard input is written off the caller's task, one writer per invocation so a child
    /// that never reads cannot stall another run's delivery; a child that exits early
    /// produces an error instead of a signal.
    private static let standardInputQueue = DispatchQueue(label: "GuesthouseRuntimeKit.ProcessRunner.stdin", qos: .utility, attributes: .concurrent)

    public init() {}

    public func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        guard FileManager.default.isExecutableFile(atPath: invocation.executable.path) else {
            throw ProcessLaunchError.executableNotFound(invocation.executable.lastPathComponent)
        }
        // A workspace folder that is gone or unreadable is a different failure from a broken
        // runtime, and reinstalling the runtime would not repair it.
        if let directory = invocation.currentDirectory, !Self.isUsableDirectory(directory) {
            throw ProcessLaunchError.workingDirectoryUnavailable(directory.lastPathComponent)
        }

        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.currentDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin: Pipe?
        switch invocation.standardInput {
        case .none:
            process.standardInput = FileHandle.nullDevice
            stdin = nil
        case .data:
            let pipe = Pipe()
            process.standardInput = pipe
            stdin = pipe
        }

        // Bounded: a consumer that falls far behind loses the oldest lines and the exit says
        // so, instead of the service growing without limit.
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessOutput.self, bufferingPolicy: .bufferingNewest(OutputReaders.maximumQueuedLines))
        let run = ProcessRun(process: process, output: stream, continuation: continuation)
        let readers = OutputReaders(continuation: continuation, maximumBytes: invocation.maximumOutputBytes) { [weak run] in
            run?.markOutputTruncated()
        }
        readers.attach(stdout.fileHandleForReading, kind: .stdout)
        readers.attach(stderr.fileHandleForReading, kind: .stderr)

        // Registered before launch: a child that exits at once must still wait for the
        // delivery attempt before its exit is reported.
        let standardInputDelivery = DispatchGroup()
        if case .data = invocation.standardInput { standardInputDelivery.enter() }
        process.terminationHandler = { [run] process in
            // Output still arriving after the drain wait expires is lost, and input still
            // undelivered after its wait is a failure; both are reported, never assumed fine.
            if readers.waitUntilDrained() == .timedOut { run.markOutputTruncated() }
            if standardInputDelivery.wait(timeout: .now() + 5) == .timedOut {
                run.markStandardInputFailed()
                run.abandonStandardInput()
            }
            let reason: ProcessExit.Reason = process.terminationReason == .uncaughtSignal
                ? .signal(process.terminationStatus)
                : .status(process.terminationStatus)
            run.finish(with: reason)
        }

        run.retainWhileRunning()
        do {
            try process.run()
        } catch {
            if case .data = invocation.standardInput { standardInputDelivery.leave() }
            readers.detach()
            run.finish(with: .status(-1))
            throw ProcessLaunchError.launchFailed(executable: invocation.executable.lastPathComponent, reason: SanitizedText(String(describing: error), limit: 120))
        }
        run.recordChildIdentity()

        // The timeout is armed before standard input is delivered, so a child that never
        // reads it is still ended at the deadline.
        let grace = invocation.terminationGracePeriod
        let timeout = invocation.timeout
        run.armTimeout(Task { [weak run] in
            try? await Task.sleep(for: timeout)
            run?.timeOut(gracePeriod: grace)
        })

        if case .data(let data) = invocation.standardInput, let stdin {
            let handle = stdin.fileHandleForWriting
            // SIGPIPE is suppressed on this descriptor alone; the process-wide disposition,
            // which children would inherit across exec, is left as it is.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            // `DispatchIO` borrows the descriptor and hands it back here; this close is the
            // only one, and it is what lets the child see end of input.
            let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: Self.standardInputQueue) { _ in
                try? handle.close()
            }
            run.attachStandardInput(channel)
            let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
            channel.write(offset: 0, data: bytes, queue: Self.standardInputQueue) { [run] done, _, error in
                if error != 0 { run.markStandardInputFailed() }
                if done {
                    channel.close()
                    standardInputDelivery.leave()
                }
            }
        }
        return run
    }

    /// Whether a working directory is there and can be entered.
    static func isUsableDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return access(url.path, X_OK) == 0
    }
}

/// Reads both pipes continuously so a chatty child can never fill a pipe and deadlock, splits
/// the bytes into records (`RecordSplitter`), and redacts each record before yielding it.
///
/// Once `maximumBytes` have been emitted the rest is discarded while the pipes keep draining.
private final class OutputReaders: @unchecked Sendable {
    enum Kind { case stdout, stderr }

    static let maximumQueuedLines = 4_096

    private let continuation: AsyncStream<ProcessOutput>.Continuation
    private let lock = NSLock()
    private let drained = DispatchGroup()
    private var splitters: [ObjectIdentifier: RecordSplitter] = [:]
    private var states: [ObjectIdentifier: Redactor.StreamState] = [:]
    private var emittedBytes = 0
    private let maximumBytes: Int
    private let truncated: @Sendable () -> Void
    private let redactor = Redactor()

    init(continuation: AsyncStream<ProcessOutput>.Continuation, maximumBytes: Int, truncated: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.maximumBytes = maximumBytes
        self.truncated = truncated
    }

    func attach(_ handle: FileHandle, kind: Kind) {
        drained.enter()
        let id = ObjectIdentifier(handle)
        lock.withLock {
            splitters[id] = RecordSplitter()
            states[id] = Redactor.StreamState()
        }
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.flush(id, kind: kind)
                self.drained.leave()
                return
            }
            self.consume(data, id: id, kind: kind)
        }
    }

    func detach() {
        // Launch failed: nothing will ever be read.
        lock.withLock { splitters.removeAll() }
        continuation.finish()
    }

    @discardableResult
    func waitUntilDrained() -> DispatchTimeoutResult {
        drained.wait(timeout: .now() + 5)
    }

    private func consume(_ data: Data, id: ObjectIdentifier, kind: Kind) {
        let records: [Data] = lock.withLock { splitters[id]?.consume(data) ?? [] }
        for record in records { emit(record, id: id, kind: kind) }
    }

    private func flush(_ id: ObjectIdentifier, kind: Kind) {
        let remainder: Data? = lock.withLock {
            var splitter = splitters.removeValue(forKey: id)
            return splitter?.flush()
        }
        if let remainder { emit(remainder, id: id, kind: kind) }
    }

    private func emit(_ lineData: Data, id: ObjectIdentifier, kind: Kind) {
        let redacted: RedactedLine? = lock.withLock {
            guard emittedBytes < maximumBytes else { return nil }
            // The ending that closed the record is charged too, so a child printing nothing
            // but newlines still reaches the cap instead of streaming for as long as it runs.
            emittedBytes += lineData.count + 1
            var state = states[id] ?? Redactor.StreamState()
            let result = redactor.redact(processOutputLine: String(decoding: lineData, as: UTF8.self), state: &state)
            states[id] = state
            return result
        }
        guard let redacted else {
            truncated()
            return
        }
        // A line the stream did not take, because the consumer fell behind or stopped
        // listening, is missing from what anyone awaiting the exit will have seen.
        switch continuation.yield(kind == .stdout ? .stdout(redacted) : .stderr(redacted)) {
        case .enqueued: break
        case .dropped, .terminated: truncated()
        @unknown default: truncated()
        }
    }
}
