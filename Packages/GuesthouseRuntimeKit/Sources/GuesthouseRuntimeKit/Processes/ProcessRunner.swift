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
    private var killTask: Task<Void, Never>?
    /// Self-reference held from launch until `finish`, so the run outlives its callers.
    private var retainedWhileRunning: ProcessRun?

    init(process: Process, output: AsyncStream<ProcessOutput>, continuation: AsyncStream<ProcessOutput>.Continuation) {
        self.process = process
        self.output = output
        self.outputContinuation = continuation
    }

    public var processIdentifier: Int32 { process.processIdentifier }

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

    func markStandardInputFailed() {
        lock.withLock { standardInputFailed = true }
    }

    func markOutputTruncated() {
        lock.withLock { outputTruncated = true }
    }

    /// Records the interruption only when termination really starts: a child that exited on
    /// its own moments earlier is never reported as interrupted.
    private func stop(gracePeriod: Duration, becauseOfTimeout: Bool) {
        let started: Bool = lock.withLock {
            guard exitResult == nil, killTask == nil, process.isRunning else { return false }
            if becauseOfTimeout { timedOut = true } else { terminationRequested = true }
            return true
        }
        guard started else { return }
        let pid = process.processIdentifier
        // Helpers the program forked are signaled too, so a timeout cannot leave a
        // descendant modifying the host or the VM after the exit is reported.
        let descendants = Self.descendants(of: pid)
        process.terminate()
        for child in descendants { kill(child, SIGTERM) }
        let task = Task { [self] in
            try? await Task.sleep(for: gracePeriod)
            guard self.process.isRunning else { return }
            for child in Self.descendants(of: pid) { kill(child, SIGKILL) }
            kill(pid, SIGKILL)
        }
        lock.withLock { killTask = task }
    }

    func finish(with reason: ProcessExit.Reason) {
        let (waiters, exit): ([CheckedContinuation<ProcessExit, Never>], ProcessExit) = lock.withLock {
            killTask?.cancel()
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
    /// Standard input is written off the caller's task; a child that never reads cannot block
    /// the runner, and a child that exits early produces an error instead of a signal.
    private static let standardInputQueue = DispatchQueue(label: "GuesthouseRuntimeKit.ProcessRunner.stdin", qos: .utility)
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    public init() {
        _ = Self.ignoreBrokenPipes
    }

    public func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        guard FileManager.default.isExecutableFile(atPath: invocation.executable.path) else {
            throw ProcessLaunchError.executableNotFound(invocation.executable.lastPathComponent)
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

        let standardInputDelivery = DispatchGroup()
        process.terminationHandler = { [run] process in
            readers.waitUntilDrained()
            // The exit reports whether input was delivered, so the write must have finished.
            _ = standardInputDelivery.wait(timeout: .now() + 5)
            let reason: ProcessExit.Reason = process.terminationReason == .uncaughtSignal
                ? .signal(process.terminationStatus)
                : .status(process.terminationStatus)
            run.finish(with: reason)
        }

        run.retainWhileRunning()
        do {
            try process.run()
        } catch {
            readers.detach()
            run.finish(with: .status(-1))
            throw ProcessLaunchError.launchFailed(executable: invocation.executable.lastPathComponent, reason: SanitizedText(String(describing: error), limit: 120))
        }

        // The timeout is armed before standard input is delivered, so a child that never
        // reads it is still ended at the deadline.
        let grace = invocation.terminationGracePeriod
        let timeout = invocation.timeout
        Task { [run] in
            try? await Task.sleep(for: timeout)
            run.timeOut(gracePeriod: grace)
        }

        if case .data(let data) = invocation.standardInput, let stdin {
            let handle = stdin.fileHandleForWriting
            standardInputDelivery.enter()
            Self.standardInputQueue.async { [run] in
                defer { standardInputDelivery.leave() }
                do {
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    run.markStandardInputFailed()
                    try? handle.close()
                }
            }
        }
        return run
    }
}

/// Reads both pipes continuously so a chatty child can never fill a pipe and deadlock, splits
/// the bytes into lines, and redacts each line before yielding it.
///
/// Bounds: a record longer than `maximumLineBytes` is emitted in pieces, `\r` ends a record
/// like `\n` (progress bars), and once `maximumBytes` have been emitted the rest is discarded
/// while the pipes keep draining.
private final class OutputReaders: @unchecked Sendable {
    enum Kind { case stdout, stderr }

    static let maximumQueuedLines = 4_096
    static let maximumLineBytes = 64 << 10

    private let continuation: AsyncStream<ProcessOutput>.Continuation
    private let lock = NSLock()
    private let drained = DispatchGroup()
    private var buffers: [ObjectIdentifier: Data] = [:]
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
            buffers[id] = Data()
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
        lock.withLock { buffers.removeAll() }
        continuation.finish()
    }

    func waitUntilDrained() {
        _ = drained.wait(timeout: .now() + 5)
    }

    private func consume(_ data: Data, id: ObjectIdentifier, kind: Kind) {
        var lines: [Data] = []
        lock.withLock {
            guard var pending = buffers[id] else { return }
            pending.append(data)
            // One linear pass: a record ends at `\n` or `\r` (a `\r\n` pair is one ending) or
            // when it reaches the per-record cap, so a chatty child costs O(bytes), not O(bytes²).
            var start = pending.startIndex
            var index = start
            var previousWasCarriageReturn = false
            while index < pending.endIndex {
                let byte = pending[index]
                if byte == 0x0A || byte == 0x0D {
                    if !(byte == 0x0A && previousWasCarriageReturn && start == index) {
                        lines.append(pending[start..<index])
                    }
                    start = index + 1
                    previousWasCarriageReturn = byte == 0x0D
                } else {
                    previousWasCarriageReturn = false
                    if index - start + 1 >= Self.maximumLineBytes {
                        lines.append(pending[start...index])
                        start = index + 1
                    }
                }
                index += 1
            }
            buffers[id] = Data(pending[start...])
        }
        for line in lines { emit(line, id: id, kind: kind) }
    }

    private func flush(_ id: ObjectIdentifier, kind: Kind) {
        let remainder: Data? = lock.withLock {
            let data = buffers.removeValue(forKey: id)
            return (data?.isEmpty == false) ? data : nil
        }
        if let remainder { emit(remainder, id: id, kind: kind) }
    }

    private func emit(_ lineData: Data, id: ObjectIdentifier, kind: Kind) {
        let redacted: RedactedLine? = lock.withLock {
            guard emittedBytes < maximumBytes else { return nil }
            emittedBytes += lineData.count
            var state = states[id] ?? Redactor.StreamState()
            let result = redactor.redact(processOutputLine: String(decoding: lineData, as: UTF8.self), state: &state)
            states[id] = state
            return result
        }
        guard let redacted else {
            truncated()
            return
        }
        if case .dropped = continuation.yield(kind == .stdout ? .stdout(redacted) : .stderr(redacted)) {
            truncated()
        }
    }
}
