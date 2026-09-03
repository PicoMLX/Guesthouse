import Darwin
import Foundation
import GuesthouseCore

/// Anything that can run a `ProcessInvocation`. `ProcessRunner` is the real one; tests and
/// the Tart backend's tests substitute a fake.
public protocol ProcessRunning: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessRun
}

/// A running or finished child process: its redacted output and its exit.
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
    private var killTask: Task<Void, Never>?

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
        lock.withLock { terminationRequested = true }
        stop(gracePeriod: gracePeriod)
    }

    func timeOut(gracePeriod: Duration) {
        lock.withLock { timedOut = true }
        stop(gracePeriod: gracePeriod)
    }

    private func stop(gracePeriod: Duration) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let task = Task { [weak self] in
            try? await Task.sleep(for: gracePeriod)
            guard let self, self.process.isRunning else { return }
            kill(pid, SIGKILL)
        }
        lock.withLock { killTask = task }
    }

    func finish(with exit: ProcessExit) {
        let waiters: [CheckedContinuation<ProcessExit, Never>] = lock.withLock {
            killTask?.cancel()
            exitResult = exit
            let pending = exitWaiters
            exitWaiters.removeAll()
            return pending
        }
        outputContinuation.finish()
        for waiter in waiters { waiter.resume(returning: exit) }
    }

    var flags: (timedOut: Bool, terminated: Bool) {
        lock.withLock { (timedOut, terminationRequested) }
    }
}

/// Launches programs with an executable URL and argument array, streams their output through
/// the redactor, enforces a timeout, and never involves a shell.
public actor ProcessRunner: ProcessRunning {
    public init() {}

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

        let (stream, continuation) = AsyncStream.makeStream(of: ProcessOutput.self, bufferingPolicy: .unbounded)
        let run = ProcessRun(process: process, output: stream, continuation: continuation)
        let readers = OutputReaders(continuation: continuation)
        readers.attach(stdout.fileHandleForReading, kind: .stdout)
        readers.attach(stderr.fileHandleForReading, kind: .stderr)

        process.terminationHandler = { [weak run] process in
            readers.waitUntilDrained()
            let reason: ProcessExit.Reason = process.terminationReason == .uncaughtSignal
                ? .signal(process.terminationStatus)
                : .status(process.terminationStatus)
            guard let run else { return }
            let flags = run.flags
            run.finish(with: ProcessExit(reason: reason, timedOut: flags.timedOut, terminated: flags.terminated))
        }

        do {
            try process.run()
        } catch {
            readers.detach()
            throw ProcessLaunchError.launchFailed(String(describing: error))
        }

        if case .data(let data) = invocation.standardInput, let stdin {
            let handle = stdin.fileHandleForWriting
            try? handle.write(contentsOf: data)
            try? handle.close()
        }

        let grace = invocation.terminationGracePeriod
        let timeout = invocation.timeout
        Task { [weak run] in
            try? await Task.sleep(for: timeout)
            run?.timeOut(gracePeriod: grace)
        }
        return run
    }
}

/// Reads both pipes continuously so a chatty child can never fill a pipe and deadlock, splits
/// the bytes into lines, and redacts each line before yielding it.
private final class OutputReaders: @unchecked Sendable {
    enum Kind { case stdout, stderr }

    private let continuation: AsyncStream<ProcessOutput>.Continuation
    private let lock = NSLock()
    private let drained = DispatchGroup()
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var states: [ObjectIdentifier: Redactor.StreamState] = [:]
    private let redactor = Redactor()

    init(continuation: AsyncStream<ProcessOutput>.Continuation) {
        self.continuation = continuation
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
        var lines: [String] = []
        lock.withLock {
            buffers[id, default: Data()].append(data)
            while let newline = buffers[id]!.firstIndex(of: 0x0A) {
                let lineData = buffers[id]!.subdata(in: buffers[id]!.startIndex..<newline)
                buffers[id]!.removeSubrange(buffers[id]!.startIndex...newline)
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        for line in lines { emit(line, id: id, kind: kind) }
    }

    private func flush(_ id: ObjectIdentifier, kind: Kind) {
        let remainder: Data? = lock.withLock {
            let data = buffers.removeValue(forKey: id)
            return (data?.isEmpty == false) ? data : nil
        }
        if let remainder { emit(String(decoding: remainder, as: UTF8.self), id: id, kind: kind) }
    }

    private func emit(_ line: String, id: ObjectIdentifier, kind: Kind) {
        let redacted: RedactedLine = lock.withLock {
            var state = states[id] ?? Redactor.StreamState()
            let result = redactor.redact(line: line, state: &state)
            states[id] = state
            return result
        }
        continuation.yield(kind == .stdout ? .stdout(redacted) : .stderr(redacted))
    }
}
