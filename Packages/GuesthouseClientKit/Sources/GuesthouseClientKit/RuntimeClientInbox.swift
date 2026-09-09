import GuesthouseCore
import Synchronization

/// Ordered callback handoff for the retained #67/#103 client (MVP-PLAN.md §3).
/// Reserve before native send. Every admitted request has independent space for its send,
/// owning reply and consumer-end notification; unsolicited traffic cannot consume it.
/// Callbacks only enqueue. ONE owner drains `take()` after each payload-free wakeup and
/// runs router/native effects outside callback locks. No tasks or native calls live here.
final class RuntimeClientInbox: Sendable {
    struct Submission: Sendable {
        let key: RuntimeRequestKey
        let request: RuntimeRequest
        let producer: RuntimeEventStream
    }
    enum Message: Sendable {
        case send(Submission)
        case reply(RuntimeRequestKey, Result<RuntimeEvent, RuntimeSessionFailure>)
        /// Reconcile directly: the normal router/consumer may already have finished.
        case unexpectedReply(RuntimeEventRouter.UncertainRequest)
        case ended(RuntimeRequestKey, RuntimeEventStream.Termination)
        case incoming(RuntimeEvent), interrupted(RuntimeSessionFailure)
        /// Stops admission permanently. The owner must retire and reconcile, not replay.
        case fault(RuntimeSessionFailure.Cause)
    }
    enum Admission: Equatable, Sendable { case admitted, full, faulted }
    typealias Reply = @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void
    private struct Reservation: Sendable {
        let context: RuntimeEventRouter.UncertainRequest
        var firstReplyID: OperationID?
        var sendTaken = false, replyQueued = false, replyTaken = false
        var endQueued = false, endTaken = false, duplicateQueued = false, duplicateTaken = true
        var handlerIssued = false, replyWindowClosed = false
        var complete: Bool { sendTaken && replyTaken && endTaken && duplicateTaken && replyWindowClosed }
    }
    private struct State: Sendable {
        var requests: [RuntimeRequestKey: Reservation] = [:]
        var queue: [Message] = []
        var incomingCount = 0, interruptionCount = 0
        var fault: RuntimeSessionFailure.Cause?
        var dropped = 0
        mutating func fail(_ cause: RuntimeSessionFailure.Cause) {
            guard fault == nil else { return }
            fault = cause; queue.append(.fault(cause)) // One reserved fault slot.
        }
    }
    static let requestLimit = RuntimeEventRouter.requestLimit
    static let incomingLimit = 128, trafficLimit = 96, interruptionLimit = 16
    // Three normal controls + one defensive duplicate per reservation, plus bounded pushes,
    // interruptions and ONE fault. Request payload sizes are validated before reservation.
    static let queueLimit = requestLimit * 4 + incomingLimit + interruptionLimit + 1
    private let state = Mutex(State())
    let wakeups: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation

    init() { (wakeups, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    deinit { wake.finish() }
    var queuedCount: Int { state.withLock { $0.queue.count } }
    var reservationCount: Int { state.withLock { $0.requests.count } }
    var droppedTraffic: Int { state.withLock { $0.dropped } }
    /// Owner checks before executing queued sends: reject known-unsent work after a fault.
    /// A fault racing an actual send still requires retirement/reconciliation, never replay.
    var terminalFailure: RuntimeSessionFailure.Cause? { state.withLock { $0.fault } }

    /// Caller validates the request and encoded size first. Refusal remains known-unsent:
    /// caller owns and rejects the producer, outside this lock. This is not router admission.
    func submit(_ submission: Submission) -> Admission {
        let result = state.withLock { state in
            guard state.fault == nil else { return Admission.faulted }
            guard state.requests.count < Self.requestLimit, state.requests[submission.key] == nil else { return .full }
            let request = submission.request
            state.requests[submission.key] = Reservation(context: .init(key: submission.key,
                environmentID: request.environment, cancellationTarget: request.cancellationTarget,
                failure: .init(cause: .malformedResponse, mayHaveMutated: request.mayMutate)))
            state.queue.append(.send(submission))
            return .admitted
        }
        if result == .admitted { wake.yield(()) }
        return result
    }

    /// Transfer this closure to the owning transport call; do not retain a separate copy.
    /// Its capture lifetime closes the duplicate window, including after the consumer finished.
    /// Only one handler may be issued per reservation. No arbitrary timer/tombstone history.
    /// Keep it alive through the send's catch path until any known-unsent rejection is recorded.
    func replyHandler(for key: RuntimeRequestKey) -> Reply? {
        let issued = state.withLock { state in
            guard var reservation = state.requests[key], !reservation.handlerIssued, !reservation.replyQueued else { return false }
            reservation.handlerIssued = true; state.requests[key] = reservation
            return true
        }
        guard issued else { return nil }
        let lifetime = ReplyLifetime(inbox: self, key: key)
        return { lifetime.inbox.replied(lifetime.key, $0) }
    }

    private func replied(_ key: RuntimeRequestKey, _ result: Result<RuntimeEvent, RuntimeSessionFailure>) {
        enqueue { state in
            guard var reservation = state.requests[key] else { return }
            if reservation.replyQueued {
                if !reservation.duplicateQueued {
                    let id: OperationID?, additionalUncertainty: Bool
                    switch result {
                    case .success(.accepted(let accepted)): id = accepted; additionalUncertainty = false
                    case .success: id = nil; additionalUncertainty = false
                    // Retirement converts a late acceptance into a failure retaining its ID.
                    case .failure(let failure): id = failure.operationID; additionalUncertainty = failure.mayHaveMutated
                    }
                    if let id, id != reservation.firstReplyID {
                        reservation.duplicateQueued = true; reservation.duplicateTaken = false
                        let context = reservation.context
                        state.queue.append(.unexpectedReply(.init(key: key, environmentID: context.environmentID,
                            cancellationTarget: context.cancellationTarget,
                            failure: context.failure.contextualized(operationID: id, mayHaveMutated: additionalUncertainty))))
                    }
                }
                state.fail(.malformedResponse)
            } else {
                reservation.replyQueued = true
                switch result {
                case .success(let event): reservation.firstReplyID = event.routingID
                case .failure(let failure): reservation.firstReplyID = failure.operationID
                }
                state.queue.append(.reply(key, result))
            }
            state.requests[key] = reservation
        }
    }

    private func replyWindowClosed(_ key: RuntimeRequestKey) {
        enqueue { state in
            guard var reservation = state.requests[key] else { return }
            reservation.replyWindowClosed = true
            if !reservation.replyQueued {
                // No closure remains that can supply a later reply. Settle an unanswered
                // invocation conservatively; known-unsent rejection must be recorded first.
                reservation.replyQueued = true
                state.queue.append(.reply(key, .failure(.init(cause: .connectionLost))))
                state.fail(.connectionLost) // Do not admit more sends on a broken reply contract.
            }
            if reservation.complete { state.requests.removeValue(forKey: key) }
            else { state.requests[key] = reservation }
        }
    }

    func ended(_ key: RuntimeRequestKey, _ reason: RuntimeEventStream.Termination) {
        enqueue { state in
            guard var reservation = state.requests[key], !reservation.endQueued else { return }
            reservation.endQueued = true; state.requests[key] = reservation
            state.queue.append(.ended(key, reason))
        }
    }

    func incoming(_ event: RuntimeEvent) {
        enqueue { state in
            guard state.fault == nil else { return }
            if event.droppable, state.incomingCount >= Self.trafficLimit {
                if state.dropped < Int.max { state.dropped += 1 }
                return
            }
            guard state.incomingCount < Self.incomingLimit else { state.fail(.oversizedResponse); return }
            state.incomingCount += 1; state.queue.append(.incoming(event))
        }
    }

    func interrupted(_ failure: RuntimeSessionFailure) {
        enqueue { state in
            guard state.fault == nil else { return }
            guard state.interruptionCount < Self.interruptionLimit else { state.fail(.oversizedResponse); return }
            state.interruptionCount += 1
            // A generation-wide notification must not acquire one request's identity.
            state.queue.append(.interrupted(.init(cause: failure.cause)))
        }
    }

    /// Owner-side timeout/fatal error. Awaiting replies still have their reserved slots.
    func fail(_ cause: RuntimeSessionFailure.Cause) {
        enqueue { $0.fail(cause) }
    }

    /// A queued owning reply beats its deadline even if the owner has not drained it yet.
    func expireReply(_ key: RuntimeRequestKey) {
        enqueue { state in
            if state.requests[key]?.replyQueued == false { state.fail(.connectionLost) }
        }
    }

    /// Only appended work wakes the owner, never discarded traffic or bookkeeping alone.
    private func enqueue(_ update: (inout State) -> Void) {
        let appended = state.withLock { state in
            let before = state.queue.count
            update(&state)
            return state.queue.count > before
        }
        if appended { wake.yield(()) }
    }

    /// Only after dequeuing a send that is KNOWN not to have reached native send. Marks its
    /// nonexistent callback settled; never use this to erase an ambiguous/late owning reply.
    func rejectedBeforeSend(_ key: RuntimeRequestKey) {
        state.withLock { state in
            guard var reservation = state.requests[key], reservation.sendTaken, !reservation.replyQueued else { return }
            reservation.replyQueued = true; reservation.replyTaken = true
            if !reservation.handlerIssued { reservation.replyWindowClosed = true }
            if reservation.complete { state.requests.removeValue(forKey: key) }
            else { state.requests[key] = reservation }
        }
    }

    /// Single-consumer drain. Returning the message transfers its lifetime OUT of the lock.
    /// Taking an end notice does not release a still-pending owning reply reservation.
    func take() -> Message? {
        state.withLock { state in
            guard !state.queue.isEmpty else { return nil }
            let message = state.queue.removeFirst()
            let key: RuntimeRequestKey?
            switch message {
            case .send(let submission):
                key = submission.key; state.requests[submission.key]?.sendTaken = true
            case .reply(let id, _): key = id; state.requests[id]?.replyTaken = true
            case .unexpectedReply(let context): key = context.key; state.requests[context.key]?.duplicateTaken = true
            case .ended(let id, _): key = id; state.requests[id]?.endTaken = true
            case .incoming: key = nil; state.incomingCount -= 1
            case .interrupted: key = nil; state.interruptionCount -= 1
            case .fault: key = nil
            }
            if let key, state.requests[key]?.complete == true { state.requests.removeValue(forKey: key) }
            return message
        }
    }
    private final class ReplyLifetime: Sendable {
        let inbox: RuntimeClientInbox, key: RuntimeRequestKey
        init(inbox: RuntimeClientInbox, key: RuntimeRequestKey) { self.inbox = inbox; self.key = key }
        deinit { inbox.replyWindowClosed(key) } // Enqueue/bookkeeping only, even on a native callback thread.
    }
}

private extension RuntimeEvent {
    var droppable: Bool {
        switch self { case .progress, .diagnostic, .status: true; default: false }
    }
}
