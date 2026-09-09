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
        case ended(RuntimeRequestKey, RuntimeEventStream.Termination)
        case incoming(RuntimeEvent), interrupted(RuntimeSessionFailure)
        /// Stops admission permanently. The owner must retire and reconcile, not replay.
        case fault(RuntimeSessionFailure.Cause)
    }
    enum Admission: Equatable, Sendable { case admitted, full, faulted }
    private struct Reservation: Sendable {
        var sendTaken = false, replyQueued = false, replyTaken = false
        var endQueued = false, endTaken = false, duplicateQueued = false, duplicateTaken = true
        var complete: Bool { sendTaken && replyTaken && endTaken && duplicateTaken }
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
            state.requests[submission.key] = Reservation()
            state.queue.append(.send(submission))
            return .admitted
        }
        if result == .admitted { wake.yield(()) }
        return result
    }

    /// Only the request's owning transport callback, never unsolicited wire traffic.
    /// The first reply remains enqueueable after overflow/consumer abandonment. One unexpected
    /// duplicate is retained too, for the router's second-ID reconciliation, then ingress faults.
    func replied(_ key: RuntimeRequestKey, _ result: Result<RuntimeEvent, RuntimeSessionFailure>) {
        state.withLock { state in
            guard var reservation = state.requests[key] else { return }
            if reservation.replyQueued {
                if !reservation.duplicateQueued {
                    reservation.duplicateQueued = true; reservation.duplicateTaken = false
                    state.queue.append(.reply(key, result))
                }
                state.fail(.malformedResponse)
            } else {
                reservation.replyQueued = true
                state.queue.append(.reply(key, result))
            }
            state.requests[key] = reservation
        }
        wake.yield(())
    }

    func ended(_ key: RuntimeRequestKey, _ reason: RuntimeEventStream.Termination) {
        state.withLock { state in
            guard var reservation = state.requests[key], !reservation.endQueued else { return }
            reservation.endQueued = true; state.requests[key] = reservation
            state.queue.append(.ended(key, reason))
        }
        wake.yield(())
    }

    func incoming(_ event: RuntimeEvent) {
        state.withLock { state in
            guard state.fault == nil else { return }
            if event.droppable, state.incomingCount >= Self.trafficLimit {
                if state.dropped < Int.max { state.dropped += 1 }
                return
            }
            guard state.incomingCount < Self.incomingLimit else { state.fail(.oversizedResponse); return }
            state.incomingCount += 1; state.queue.append(.incoming(event))
        }
        wake.yield(())
    }

    func interrupted(_ failure: RuntimeSessionFailure) {
        state.withLock { state in
            guard state.fault == nil else { return }
            guard state.interruptionCount < Self.interruptionLimit else { state.fail(.oversizedResponse); return }
            state.interruptionCount += 1
            // A generation-wide notification must not acquire one request's identity.
            state.queue.append(.interrupted(.init(cause: failure.cause)))
        }
        wake.yield(())
    }

    /// Owner-side timeout/fatal error. Awaiting replies still have their reserved slots.
    func fail(_ cause: RuntimeSessionFailure.Cause) {
        state.withLock { $0.fail(cause) }
        wake.yield(())
    }

    /// Only after dequeuing a send that is KNOWN not to have reached native send. Marks its
    /// nonexistent callback settled; never use this to erase an ambiguous/late owning reply.
    func rejectedBeforeSend(_ key: RuntimeRequestKey) {
        state.withLock { state in
            guard var reservation = state.requests[key], reservation.sendTaken, !reservation.replyQueued else { return }
            reservation.replyQueued = true; reservation.replyTaken = true
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
            case .reply(let id, _):
                key = id
                if state.requests[id]?.replyTaken == false { state.requests[id]?.replyTaken = true }
                else { state.requests[id]?.duplicateTaken = true }
            case .ended(let id, _): key = id; state.requests[id]?.endTaken = true
            case .incoming: key = nil; state.incomingCount -= 1
            case .interrupted: key = nil; state.interruptionCount -= 1
            case .fault: key = nil
            }
            if let key, state.requests[key]?.complete == true { state.requests.removeValue(forKey: key) }
            return message
        }
    }
}

private extension RuntimeEvent {
    var droppable: Bool {
        switch self { case .progress, .diagnostic, .status: true; default: false }
    }
}
