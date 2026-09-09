import Darwin
import Foundation

/// Direct-child execution evidence, NOT provider/mutation success or descendant quiescence.
/// No raw bytes/arguments/errors can enter diagnostics through this report (ADR 0003).
struct ProcessReport: Sendable {
    let childExit: Result<OwnedChild.ExitReason, OwnedChild.Failure>?
    let timedOut: Bool, canceled: Bool, terminationRefused: Bool
    let input: InputDelivery.End?, inputClosed: Bool, outputComplete: Bool
    /// Always requires a separate operation-specific inspection/ownership decision.
    let descendantScopeUnproven = true
}

/// A facade's release discards temporary responses, but never abandons owned-child reaping.
final class ProcessRun: Sendable {
    enum WaitFailure: Error { case alreadyWaiting }
    private let driver: Driver
    init(child: OwnedChild, readers: OutputReaders, input: InputDelivery?, grace: Duration) {
        driver = Driver(child: child, readers: readers, input: input, grace: grace)
    }
    deinit { let driver = driver; Task { await driver.abandonResponse() } }
    func start(deadline: ContinuousClock.Instant, input: Data?) async { await driver.start(deadline: deadline, data: input) }
    func terminate(gracePeriod: Duration) async { await driver.stop(grace: gracePeriod, timedOut: false) }
    func waitForExit() async throws -> ProcessReport {
        try await withTaskCancellationHandler {
            try await driver.waitForExit()
        } onCancel: {
            Task { await self.driver.cancelWait() }
        }
    }
    /// One transfer after completion. Callers parse only complete responses and release bytes.
    func takeOutput() async -> OutputReaders.Response? { await driver.takeOutput() }

    private actor Driver {
        let child: OwnedChild, readers: OutputReaders, input: InputDelivery?, grace: Duration
        var report: ProcessReport?
        var response: OutputReaders.Response?
        var waiter: CheckedContinuation<ProcessReport, Never>?
        var childExit: Result<OwnedChild.ExitReason, OwnedChild.Failure>?
        var timedOut = false, canceled = false, refused = false, abandoned = false
        var began = false, stopping = false, generation = 0
        var killAt: ContinuousClock.Instant?
        var timeoutTask: Task<Void, Never>?, escalationTask: Task<Void, Never>?, recoveryTask: Task<Void, Never>?

        init(child: OwnedChild, readers: OutputReaders, input: InputDelivery?, grace: Duration) {
            self.child = child; self.readers = readers; self.input = input; self.grace = grace
        }
        func start(deadline: ContinuousClock.Instant, data: Data?) {
            guard !began else { return }
            began = true
            // One observer retains this controller until this exact child is reaped, even
            // when every facade/waiter is gone. It retains no raw response after abandonment.
            Task { [self, child] in reaped(await child.waitForReapedExit()) }
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                await self?.deadlineExpired()
            }
            if let data { input?.start(data) }
        }
        func waitForExit() async throws -> ProcessReport {
            if let report { return report }
            guard waiter == nil else { throw WaitFailure.alreadyWaiting }
            return await withCheckedContinuation { waiter = $0 }
        }
        func takeOutput() -> OutputReaders.Response? {
            defer { response = nil }
            return response
        }
        func abandonResponse() { abandoned = true; response = nil }
        func cancelWait() { stop(grace: grace, timedOut: false) }
        func deadlineExpired() { stop(grace: grace, timedOut: true) }

        func stop(grace: Duration, timedOut becauseOfTimeout: Bool) {
            guard report == nil else { return } // Never rewrite a completed outcome.
            if becauseOfTimeout { timedOut = true } else { canceled = true }
            if childExit != nil {
                readers.detach(); input?.cancel()
                return // The bounded drain worker commits all interruption flags.
            }
            let deadline = ContinuousClock.now + min(.seconds(60), max(.zero, grace))
            if let killAt, deadline >= killAt { return }
            killAt = deadline; generation += 1
            let current = generation
            if !stopping { stopping = true; record(child.signal(SIGTERM)) }
            escalationTask?.cancel()
            escalationTask = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                await self?.escalate(current)
            }
        }
        func record(_ result: OwnedChild.SignalResult) {
            switch result {
            case .refused, .authorityLost: refused = true
            case .delivered, .alreadyExited, .alreadyReaped: break
            }
        }
        func escalate(_ current: Int) {
            guard report == nil, childExit == nil, generation == current else { return }
            record(child.signal(SIGKILL))
            // Delivery is not exit. Bound the caller's cleanup wait even if a signal was
            // refused or the kernel has not made the child waitable. Its owner keeps reaping.
            escalationTask = nil
            recoveryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await self?.finish(inputClosed: false)
            }
        }
        func reaped(_ result: Result<OwnedChild.ExitReason, OwnedChild.Failure>) {
            guard report == nil else { return }
            childExit = result
            escalationTask?.cancel(); escalationTask = nil
            recoveryTask?.cancel(); recoveryTask = nil
            // Both channels share one absolute shutdown window. Never block this actor.
            let deadline = DispatchTime.now() + .seconds(5)
            let readers = readers, input = input
            Task { [self] in
                let closed = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        readers.waitUntilDrained(by: deadline)
                        continuation.resume(returning: input?.waitUntilClosed(by: deadline) ?? true)
                    }
                }
                finish(inputClosed: closed)
            }
        }
        func finish(inputClosed: Bool) {
            guard report == nil else { return }
            readers.detach(); input?.cancel()
            let bytes = readers.takeResponse()
            let value = ProcessReport(childExit: childExit, timedOut: timedOut, canceled: canceled,
                terminationRefused: refused, input: input?.end, inputClosed: inputClosed,
                outputComplete: bytes?.isComplete == true)
            report = value
            if !abandoned { response = bytes }
            timeoutTask?.cancel(); timeoutTask = nil
            escalationTask?.cancel(); escalationTask = nil
            recoveryTask?.cancel(); recoveryTask = nil
            let pending = waiter; waiter = nil
            pending?.resume(returning: value)
        }
    }
}
