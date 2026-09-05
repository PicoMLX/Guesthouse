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
    /// A process this run owned was still itself when SIGKILL was refused, so it is still
    /// running and what it was doing has an unknown outcome.
    private var terminationRefused = false
    /// The child has ended and its pipes and undelivered input are being given their window
    /// to settle. A deadline that expires now is one this run can still be told about.
    private var shuttingDown = false
    /// The invocation's deadline expired during that window, so nothing is waited for any
    /// longer: what has not arrived is reported as lost instead.
    private var shutdownGivenUp = false
    /// Set under the same lock that reads it, so two overlapping requests cannot each start
    /// their own escalation of the same process graph.
    private var terminating = false
    /// Whether the process graph has been captured and signaled. No escalation is scheduled
    /// before this: a shorter deadline installed while the scan is still running would kill
    /// the child before the helpers it forked had been enumerated.
    private var terminationBegun = false
    /// When SIGKILL is due, and which escalation owns that deadline: an earlier deadline
    /// supersedes the one already waiting, and the superseded task does nothing.
    private var killDeadline: ContinuousClock.Instant?
    private var killGeneration = 0
    /// The escalation currently waiting, so one superseded by an earlier deadline can be
    /// cancelled instead of sleeping out its original grace period holding this run alive.
    private var escalationTask: Task<Void, Never>?
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

    /// The child has ended; what it left holding the pipes and its input is being waited for.
    func beginShutdown() {
        lock.withLock { shuttingDown = true }
    }

    /// Whether that wait has been given up because the invocation's deadline expired inside it.
    var shutdownAbandoned: Bool { lock.withLock { shutdownGivenUp } }

    /// What one request has to do about a termination that may already be under way.
    private enum TerminationStep {
        case ignore
        case begin
        case shorten
    }

    /// Records the interruption while the run can still be interrupted: once the outcome has
    /// been reported nothing is left to stop, and a request that arrives then changes nothing.
    ///
    /// - Returns: whether this call is the one that began the termination.
    @discardableResult
    func stop(gracePeriod: Duration, becauseOfTimeout: Bool) -> Bool {
        let deadline = ContinuousClock.now + gracePeriod
        let step: TerminationStep = lock.withLock {
            // A run that has already reported is over and nothing can change what it said. Up
            // to that moment the request counts, whether or not the direct child is still
            // running: helpers it forked can hold the run open after it exits — captured ones
            // through their escalation, uncaptured ones by keeping the pipes the shutdown is
            // draining — and a deadline that expires in that window is one the caller has to
            // be told about, not one the child's exit cancels.
            guard exitResult == nil else { return .ignore }
            if becauseOfTimeout { timedOut = true } else { terminationRequested = true }
            // The deadline expired while the run was waiting on pipes and input nothing may
            // still be holding: that wait ends here rather than running out its own window.
            if becauseOfTimeout, shuttingDown { shutdownGivenUp = true }
            // A request that would escalate no earlier than the one already waiting changes
            // nothing; an earlier one takes over, so a caller asking for a long grace period
            // cannot stretch the invocation past its own deadline.
            if terminating, let current = killDeadline, deadline >= current { return .ignore }
            let step: TerminationStep = terminating ? .shorten : .begin
            terminating = true
            killDeadline = deadline
            killGeneration += 1
            return step
        }
        switch step {
        case .ignore:
            return false
        case .begin:
            // The capture and SIGTERM complete before any escalation is scheduled, so a
            // shorter deadline arriving mid-scan cannot SIGKILL the child while the helpers
            // it forked are still being enumerated and would then survive it.
            beginTermination()
            scheduleEscalation()
            return true
        case .shorten:
            scheduleEscalation()
            return false
        }
    }

    /// SIGTERM for the child and for every helper it had forked, so a timeout cannot leave a
    /// descendant modifying the host or the VM after the exit is reported. Each helper is
    /// captured with its start time and signaled only while it is still that process.
    private func beginTermination() {
        let pid = process.processIdentifier
        let child = lock.withLock { childStart }
        var captured: [pid_t: Date] = [:]
        // The processes below a PID are only ours while the PID is still the child's. It can
        // exit between the check in `stop` and this scan, and the kernel can hand the PID to an
        // unrelated process, whose children would then be captured and signaled as if they were
        // helpers this run had forked (MVP-PLAN.md §4).
        if let child, Self.startTime(of: pid) == child {
            captured = Self.descendants(of: pid)
        }
        lock.withLock { capturedDescendants = captured }
        // The direct child is signaled by identity like every helper: it can exit during the
        // scan above, and the kernel can hand its PID to an unrelated process before this line.
        Self.signalIfUnchanged(SIGTERM, to: pid, startedAt: child)
        for (helper, start) in captured { Self.signalIfUnchanged(SIGTERM, to: helper, startedAt: start) }
        lock.withLock { terminationBegun = true }
    }

    /// Schedules SIGKILL for the deadline that stands now, replacing whatever was waiting.
    ///
    /// Nothing is scheduled until the initial capture and SIGTERM have finished; the `begin`
    /// path calls this again once they have, and it then schedules whatever deadline stands at
    /// that moment, so a shorter one that arrived mid-scan is honoured rather than lost.
    private func scheduleEscalation() {
        let scheduled: (deadline: ContinuousClock.Instant, generation: Int)? = lock.withLock {
            guard terminationBegun, let deadline = killDeadline else { return nil }
            return (deadline, killGeneration)
        }
        guard let scheduled else { return }
        let task = escalate(until: scheduled.deadline, generation: scheduled.generation)
        // Whichever task no longer owns the deadline is cancelled rather than left to sleep
        // out its original grace period holding this run, its process, its output buffer and
        // its standard input channel alive.
        let superseded: Task<Void, Never>? = lock.withLock {
            guard killGeneration == scheduled.generation else { return task }
            let previous = escalationTask
            escalationTask = task
            return previous
        }
        superseded?.cancel()
    }

    /// SIGKILL for whatever ignored SIGTERM, when the grace period ends. Deliberately not tied
    /// to the child's own exit: a descendant still cleaning up keeps the whole grace period
    /// even when its parent exits at once.
    ///
    /// The wait runs to the absolute instant the deadline names rather than for the length of
    /// the grace period, so the time already spent enumerating a large process graph counts
    /// towards it and an invocation cannot outlive its own timeout.
    private func escalate(until deadline: ContinuousClock.Instant, generation: Int) -> Task<Void, Never> {
        let pid = process.processIdentifier
        return Task { [self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            let state: (captured: [pid_t: Date], child: Date?)? = lock.withLock {
                // A later request with an earlier deadline has taken this over.
                guard killGeneration == generation else { return nil }
                escalationTask = nil
                return (capturedDescendants, childStart)
            }
            guard let (captured, child) = state else { return }
            // The deadline is what tells `reportWhenGraphIsQuiet` that something is still
            // pending, so it is cleared only once every signal below has been sent: clearing it
            // first would let the exit be reported, with a large graph, while this is still
            // working through it.
            defer { lock.withLock { if killGeneration == generation { killDeadline = nil } } }
            // A signal the kernel refuses for a process that is still the one captured leaves
            // that process running with nothing further this run can do about it. Waiting for
            // it would never end, so the run reports instead — and says so, because the
            // outcome of whatever it was still doing is unknown (MVP-PLAN.md §4).
            var refused = false
            for (descendant, start) in captured {
                refused = Self.signalIfUnchanged(SIGKILL, to: descendant, startedAt: start) == .refused || refused
            }
            // Helpers first seen now carry the identity they were found with as well, and are
            // only looked for while the child is still ours: once its PID belongs to somebody
            // else, the processes below it are strangers.
            if let child, Self.startTime(of: pid) == child {
                for (descendant, start) in Self.descendants(of: pid) where captured[descendant] == nil {
                    refused = Self.signalIfUnchanged(SIGKILL, to: descendant, startedAt: start) == .refused || refused
                }
            }
            refused = Self.signalIfUnchanged(SIGKILL, to: pid, startedAt: child) == .refused || refused
            if refused { lock.withLock { terminationRefused = true } }
        }
    }

    func finish(with reason: ProcessExit.Reason) {
        // The handler captured this run; releasing it breaks the run/process cycle.
        process.terminationHandler = nil
        // Only the reason is settled here. The timeout stays armed until the run actually
        // reports — while a captured helper is being given a caller's grace period, the
        // invocation's own deadline is the only thing that can shorten it — so the run can
        // still time out, and output can still be dropped, after the child has exited. The
        // flags are therefore read where the outcome is committed, not here, or a caller would
        // be told only that a termination was requested when the deadline is what expired.
        outputContinuation.finish()
        reportWhenGraphIsQuiet(reason)
    }

    /// The child has ended; the run is over once nothing it owned is still running.
    ///
    /// A helper that inherited the child's pipes can outlive it, and the escalation
    /// deliberately leaves such a helper the whole grace period. Reporting the exit while one
    /// is still changing the host would let a coordinator inspect state or begin the next
    /// mutation on top of it (MVP-PLAN.md §4), so the outcome is held until the captured
    /// helpers are gone or the escalation that kills them has run. A run that was never
    /// terminated captured nothing and reports at once.
    private func reportWhenGraphIsQuiet(_ reason: ProcessExit.Reason) {
        guard terminationSetupPending() || !liveCapturedDescendants().isEmpty else {
            report(reason)
            return
        }
        Task { [self] in
            // A child that exits while the scan is still running has captured nothing yet, and
            // an empty map here would mean "no helpers" rather than "not looked yet"; the
            // helpers it forked are still about to be signaled, so wait for the map first.
            while terminationSetupPending() {
                try? await Task.sleep(for: .milliseconds(5))
            }
            while !liveCapturedDescendants().isEmpty, escalationDeadline != nil {
                try? await Task.sleep(for: .milliseconds(25))
            }
            report(reason)
        }
    }

    /// Whether a termination has started but has not yet captured and signaled the graph.
    private func terminationSetupPending() -> Bool {
        lock.withLock { terminating && !terminationBegun }
    }

    /// The helpers captured when termination began that are still the processes captured.
    private func liveCapturedDescendants() -> [pid_t] {
        let captured = lock.withLock { capturedDescendants }
        return captured.compactMap { pid, start in Self.startTime(of: pid) == start ? pid : nil }
    }

    private func report(_ reason: ProcessExit.Reason) {
        // What the run reports is read as the outcome is committed: everything a caller is told
        // besides the reason can still change between the child's exit and this moment.
        let outcome: (exit: ProcessExit, waiters: [CheckedContinuation<ProcessExit, Never>], escalation: Task<Void, Never>?) = lock.withLock {
            let exit = ProcessExit(reason: reason, timedOut: timedOut, terminated: terminationRequested, standardInputFailed: standardInputFailed, outputTruncated: outputTruncated, terminationRefused: terminationRefused)
            exitResult = exit
            // Nothing is left for the deadline to shorten, so the task is released rather than
            // left to sleep out a long timeout holding this run alive.
            timeoutTask?.cancel()
            timeoutTask = nil
            // The graph this would escalate against is proven quiet, and `stop` refuses to
            // arm another one once the exit is recorded, so the pending SIGKILL has nothing
            // left to reach. Releasing it here keeps a run that answered in milliseconds from
            // being held — with its process, its output buffer and its input channel — for the
            // rest of a grace period that can be hours through `terminate(gracePeriod:)`.
            let escalation = escalationTask
            escalationTask = nil
            killDeadline = nil
            let pending = exitWaiters
            exitWaiters.removeAll()
            retainedWhileRunning = nil
            return (exit, pending, escalation)
        }
        outcome.escalation?.cancel()
        for waiter in outcome.waiters { waiter.resume(returning: outcome.exit) }
    }

    /// What a signal to a captured process did. A refusal has to be told from a process that
    /// is simply gone: the first leaves something this run owned still running, and the caller
    /// has to hear about it; the second is the ordinary end of a helper.
    enum SignalOutcome: Hashable, Sendable {
        case delivered
        /// The PID is no longer the process that was captured, or it ended between the check
        /// and the signal. Nothing this run owned is left at that PID.
        case gone
        /// Still the captured process, and the signal was refused — a helper that has become
        /// something this service may not signal, say. It is still running.
        case refused
    }

    /// Signals `pid` only while it is still the process whose start time was captured. A PID
    /// the kernel handed to somebody else after that process exited is left alone, whatever
    /// the delay between capturing it and signaling it (MVP-PLAN.md §4).
    @discardableResult
    static func signalIfUnchanged(_ signal: Int32, to pid: pid_t, startedAt start: Date?) -> SignalOutcome {
        guard let start, startTime(of: pid) == start else { return .gone }
        guard kill(pid, signal) != 0 else { return .delivered }
        // The process ended in the instant between the identity check and the signal, which is
        // the outcome the signal was for.
        return errno == ESRCH ? .gone : .refused
    }

    /// The kernel's start time for `pid`, the identity that tells a reused PID from the
    /// process that was captured; `nil` when the process cannot be read.
    static func startTime(of pid: pid_t) -> Date? { identity(of: pid)?.start }

    /// The kernel's start time and parent for `pid`, read in one call so a PID can be judged
    /// by both at the moment it is seen.
    static func identity(of pid: pid_t) -> (start: Date, parent: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return (Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000), info.kp_eproc.e_ppid)
    }

    /// Every live descendant of `pid`, each with the identity it had when it was found.
    ///
    /// The identity is read as each PID is listed rather than after the whole graph has been
    /// walked: a listed descendant can exit mid-walk and the kernel can hand its PID to an
    /// unrelated process, whose start time would then be recorded as a helper's and whose
    /// process would later be signaled as one (MVP-PLAN.md §4). The parent is read in the same
    /// call and has to still be the process this PID was listed under, so a PID reused in that
    /// instant is kept only when whoever holds it is a child of the same parent — which makes
    /// it a descendant of this run after all.
    ///
    /// `proc_listchildpids` reports counts of pids, not bytes.
    static func descendants(of pid: pid_t) -> [pid_t: Date] {
        var found: [pid_t: Date] = [:]
        var queue = [pid]
        while let parent = queue.popLast() {
            let expected = proc_listchildpids(parent, nil, 0)
            guard expected > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: Int(expected) + 16)
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                proc_listchildpids(parent, pointer.baseAddress, Int32(pointer.count * MemoryLayout<pid_t>.size))
            }
            for child in buffer.prefix(max(0, Int(count))) where child > 0 && found[child] == nil {
                guard let identity = identity(of: child), identity.parent == parent else { continue }
                found[child] = identity.start
                queue.append(child)
            }
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
            // The two share one deadline: a child that leaves a helper holding the output pipe
            // and never reads its input would otherwise cost a full window each, and the pair
            // can outlast the invocation's own timeout and grace period.
            //
            // The window is also given up as soon as the invocation's own deadline expires
            // inside it: a helper that inherited the pipes never closes them, and waiting the
            // whole window on one would let a run advertising a limit of milliseconds return
            // five seconds later. A deadline that expired before the child did is not this
            // case — the output was flowing then, and what the child produced is still worth
            // draining — so only a timeout that arrives during the shutdown ends it.
            run.beginShutdown()
            let shutdown = DispatchTime.now() + OutputReaders.shutdownWindow
            let abandoned = { run.shutdownAbandoned }
            if readers.waitUntilDrained(by: shutdown, abandonedWhen: abandoned) == .timedOut { run.markOutputTruncated() }
            if OutputReaders.wait(standardInputDelivery, by: shutdown, abandonedWhen: abandoned) == .timedOut {
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

    /// Whether a working directory is there, is a directory in its own right, and can be
    /// entered.
    ///
    /// `lstat` rather than `stat`, so the entry itself is examined and not what it points at:
    /// a workspace directory the guest replaced with a link to somewhere else would otherwise
    /// be accepted here and the child would run in the target, which is exactly the symlink
    /// escape MVP-PLAN.md §3 refuses.
    static func isUsableDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
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
    /// How long a finished child's pipes and its undelivered input have, together, to settle.
    static let shutdownWindow: DispatchTimeInterval = .seconds(5)

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
    func waitUntilDrained(by deadline: DispatchTime, abandonedWhen abandoned: () -> Bool = { false }) -> DispatchTimeoutResult {
        Self.wait(drained, by: deadline, abandonedWhen: abandoned)
    }

    /// Waits for a group in slices, so waiting can be given up before the deadline.
    ///
    /// A helper that inherited the child's pipes never closes them, and a child that never
    /// reads its input never takes it, so this wait is the one place a run can outlive the
    /// deadline it advertised. Asking again every few milliseconds costs nothing measurable
    /// against a window of seconds and lets the invocation's own deadline end it.
    static func wait(_ group: DispatchGroup, by deadline: DispatchTime, abandonedWhen abandoned: () -> Bool) -> DispatchTimeoutResult {
        while true {
            let slice = min(DispatchTime.now() + .milliseconds(25), deadline)
            if group.wait(timeout: slice) == .success { return .success }
            if DispatchTime.now() >= deadline || abandoned() { return .timedOut }
        }
    }

    private func consume(_ data: Data, id: ObjectIdentifier, kind: Kind) {
        let records: [RecordSplitter.Record] = lock.withLock { splitters[id]?.consume(data) ?? [] }
        for record in records { emit(record, id: id, kind: kind) }
    }

    private func flush(_ id: ObjectIdentifier, kind: Kind) {
        let remainder: RecordSplitter.Record? = lock.withLock {
            var splitter = splitters.removeValue(forKey: id)
            return splitter?.flush()
        }
        if let remainder { emit(remainder, id: id, kind: kind) }
    }

    private func emit(_ record: RecordSplitter.Record, id: ObjectIdentifier, kind: Kind) {
        let lineData = record.bytes
        let redacted: RedactedLine? = lock.withLock {
            // The ending that closed the record is charged too, so a child printing nothing
            // but newlines still reaches the cap instead of streaming for as long as it runs.
            let cost = lineData.count + 1
            // A record is admitted only when the whole of it fits. One record can be 64 KiB,
            // so admitting one against a single remaining byte would overshoot the bound the
            // run promises; cutting it to fit instead could hand out the head of a token the
            // redactor only recognizes whole. Reaching the cap ends the output for the run,
            // so what is delivered is a prefix rather than a gapped selection.
            guard emittedBytes + cost <= maximumBytes else {
                emittedBytes = maximumBytes
                return nil
            }
            emittedBytes += cost
            var state = states[id] ?? Redactor.StreamState()
            let result = redactor.redact(
                processOutputLine: String(decoding: lineData, as: UTF8.self),
                // A record cut out of an over-long line carries the context of the record it
                // was cut from, whichever byte the cut fell on.
                continuesPreviousRecord: record.continuesPrevious,
                state: &state
            )
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
