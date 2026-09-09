import Foundation
import GuesthouseCore

/// Native backend owner migrated from #67/#103 (MVP-PLAN.md §3, ADR 0003).
/// The public configuration remains query-only until runtime mutations/recovery integrate.
/// Keep the backend alive while inspecting reconciliation; dropping it retires its transport.
public final class RuntimeClient: RuntimeBackend {
    typealias Deadline = @Sendable () async throws -> Void
    private let inbox: RuntimeClientInbox
    private let driver: Driver
    private let drain: Task<Void, Never>
    private let permitsOperations: Bool

    public convenience init() { self.init(connect: nil, permitsOperations: false) }

    init(connect: XPCRuntimeTransport.Connect?, permitsOperations: Bool = true,
         deadline: @escaping Deadline = { try await Task.sleep(for: .seconds(10)) }) {
        let inbox = RuntimeClientInbox()
        let transport: XPCRuntimeTransport
        if let connect { transport = .init(incoming: { inbox.incoming($0) }, interrupted: { inbox.interrupted($0) }, connect: connect) }
        else { transport = .init(incoming: { inbox.incoming($0) }, interrupted: { inbox.interrupted($0) }) }
        let driver = Driver(inbox: inbox, transport: transport, deadline: deadline)
        self.inbox = inbox; self.driver = driver; self.permitsOperations = permitsOperations
        drain = Task { [weak driver] in
            for await _ in inbox.wakeups {
                if Task.isCancelled { return }
                guard let driver else { return }
                await driver.flush() // Take AND route on one actor; no competing mailbox.
            }
        }
    }

    deinit { drain.cancel() } // Driver's isolated cleanup retires native state, never a callback.

    public func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        let key = RuntimeRequestKey()
        let (producer, stream) = RuntimeEventStream.make(mayHaveMutated: request.mayMutate) { [self] reason in
            inbox.ended(key, reason) // End callback only enqueues; never performs native cleanup.
        }
        do {
            if !permitsOperations, request != .runtimeVersion { throw GuesthouseError.invalidRequest(.unsupportedOperation) }
            let envelope = RuntimeRequestEnvelope(request: request)
            try RequestValidator.validate(envelope)
            try RequestValidator.validateEncodedSize(JSONEncoder().encode(envelope))
            if Task.isCancelled { throw GuesthouseError.canceled }
            switch inbox.submit(.init(key: key, request: request, producer: producer)) {
            case .admitted: break
            case .full: producer.rejectBeforeSend(.invalidRequest(.tooManyInFlight))
            case .faulted: producer.rejectBeforeSend(.runtimeIncompatible)
            }
        } catch let error as GuesthouseError { producer.rejectBeforeSend(error) }
        catch let error as RequestValidationError { producer.rejectBeforeSend(error.guesthouseError) }
        catch { producer.rejectBeforeSend(.invalidRequest(.malformed)) }
        return stream
    }

    // Package-only recovery/test seam. No raw requests, bytes or diagnostics are exported.
    func reconciliation() async -> ([RuntimeEventRouter.UncertainRequest], Set<OperationID>) {
        await driver.reconciliation()
    }
    func flush() async { await driver.flush() }
    /// Finish admission and issue native cleanup before the GUI enables another check.
    /// Pending owning replies may still enrich reconciliation while this backend is retained.
    func close() async { await driver.close() }

    private actor Driver {
        let inbox: RuntimeClientInbox, transport: XPCRuntimeTransport, deadline: Deadline
        var router = RuntimeEventRouter()
        var timers: [RuntimeRequestKey: Task<Void, Never>] = [:]
        var cancelStreams: [RuntimeRequestKey: AsyncThrowingStream<RuntimeEvent, any Error>] = [:]
        var uncertain: [RuntimeEventRouter.UncertainRequest] = []
        var inspectTargets: Set<OperationID> = []
        var admissions = 0
        init(inbox: RuntimeClientInbox, transport: XPCRuntimeTransport, deadline: @escaping Deadline) {
            self.inbox = inbox; self.transport = transport; self.deadline = deadline
        }
        isolated deinit {
            for timer in timers.values { timer.cancel() }
            transport.retireCurrent()
        }
        func reconciliation() -> ([RuntimeEventRouter.UncertainRequest], Set<OperationID>) { (uncertain, inspectTargets) }
        func close() {
            inbox.fail(.connectionLost)
            flush()
            transport.retireCurrent()
            for timer in timers.values { timer.cancel() }
        }
        func flush() {
            // Bound one actor turn. Any work left arrived during this batch and queued a wakeup.
            for _ in 0..<RuntimeClientInbox.queueLimit {
                guard !Task.isCancelled, let item = inbox.take() else { return }
                handle(item)
            }
        }

        func handle(_ item: RuntimeClientInbox.Message) {
            let effects: [RuntimeEventRouter.Effect]
            switch item {
            case .send(let submission): start(submission); return
            case .reply(let key, let result):
                timers.removeValue(forKey: key)?.cancel()
                effects = router.reply(result, to: key)
            case .unexpectedReply(let context): effects = [.unknownOutcome(context)]
            case .incoming(let event): effects = router.incoming(event)
            case .interrupted(let failure): effects = router.interrupted(failure)
            case .ended(let key, let reason):
                cancelStreams.removeValue(forKey: key)
                effects = router.consumerEnded(key, reason: reason)
            case .fault(let cause): effects = router.invalidate(cause)
            }
            apply(effects)
        }

        private func start(_ submission: RuntimeClientInbox.Submission) {
            let key = submission.key, request = submission.request
            // Finite lifetime budget also bounds retained recovery facts (at most two IDs
            // per admitted request). A new backend requires explicit reconciliation, not replay.
            guard admissions < RuntimeEventRouter.lifetimeLimit, inbox.terminalFailure == nil else {
                reject(submission, .runtimeIncompatible); return
            }
            if request.mayMutate, request.cancellationTarget == nil, !uncertain.isEmpty || !inspectTargets.isEmpty {
                reject(submission, .runtimeIncompatible); return
            }
            guard router.register(key, request: request, producer: submission.producer) == .admitted else {
                reject(submission, .invalidRequest(.tooManyInFlight)); return
            }
            guard let reply = inbox.replyHandler(for: key) else {
                _ = router.rejected(key, error: .invalidRequest(.malformed))
                inbox.rejectedBeforeSend(key); inbox.fail(.malformedResponse); return
            }
            defer { withExtendedLifetime(reply) {} } // Keep catch's known-unsent settlement ahead of closure release.
            timers[key] = Self.timer(inbox: inbox, key: key, deadline: deadline)
            do {
                try transport.send(.init(request: request), reply: reply)
                admissions += 1
            } catch {
                timers.removeValue(forKey: key)?.cancel()
                let fixed: GuesthouseError
                if let error = error as? GuesthouseError { fixed = error }
                else if let failure = error as? RuntimeSessionFailure {
                    switch failure.cause {
                    case .connectionLost: fixed = .runtimeIncompatible
                    case .malformedResponse: fixed = .invalidRuntimeReply(.malformed)
                    case .oversizedResponse: fixed = .invalidRuntimeReply(.oversized)
                    case .protocolMismatch(let service): fixed = .protocolMismatch(client: RuntimeProtocolVersion.current.rawValue, service: service)
                    }
                } else { fixed = .runtimeIncompatible }
                _ = router.rejected(key, error: fixed)
                inbox.rejectedBeforeSend(key) // XPCRuntimeTransport throws only before native send.
                if request.cancellationTarget != nil { inbox.fail(.connectionLost) }
            }
        }

        private func reject(_ submission: RuntimeClientInbox.Submission, _ error: GuesthouseError) {
            inbox.rejectedBeforeSend(submission.key)
            submission.producer.rejectBeforeSend(error)
            if submission.request.cancellationTarget != nil { inbox.fail(.connectionLost) }
        }

        private func apply(_ effects: [RuntimeEventRouter.Effect]) {
            // Store uncertainty before executing any effect that could produce more callbacks.
            for case .unknownOutcome(let context) in effects { remember(context) }
            for effect in effects {
                switch effect {
                case .unknownOutcome: break
                case .retireConnection: transport.retireCurrent()
                case .cancel(let id): cancel(id)
                }
            }
        }

        private func remember(_ context: RuntimeEventRouter.UncertainRequest) {
            // A late first ID enriches the earlier ID-less failure, not another operation.
            if let index = uncertain.firstIndex(where: { $0.key === context.key &&
                ($0.failure.operationID == context.failure.operationID || $0.failure.operationID == nil) }) {
                uncertain[index] = context
            } else { uncertain.append(context) }
        }

        private func cancel(_ id: OperationID) {
            inspectTargets.insert(id) // Even a cancel acknowledgment does not prove the target stopped.
            let key = RuntimeRequestKey()
            let (producer, stream) = RuntimeEventStream.make(mayHaveMutated: true) { [inbox] in inbox.ended(key, $0) }
            // Retain this internal consumer until its end notice; never fire-and-forget the reply.
            cancelStreams[key] = stream
            if inbox.submit(.init(key: key, request: .cancelOperation(id), producer: producer)) != .admitted {
                cancelStreams.removeValue(forKey: key)
                producer.rejectBeforeSend(.runtimeIncompatible)
                inbox.fail(.connectionLost) // Cannot safely cancel: retire and preserve the target for inspection.
            }
        }

        private nonisolated static func timer(inbox: RuntimeClientInbox, key: RuntimeRequestKey,
                                             deadline: @escaping Deadline) -> Task<Void, Never> {
            Task {
                do { try await deadline(); if !Task.isCancelled { inbox.expireReply(key) } }
                catch {} // Cancellation ends the timer; no fabricated native reply or retry.
            }
        }
    }
}
