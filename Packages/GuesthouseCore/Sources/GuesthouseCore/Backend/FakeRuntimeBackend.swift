import Foundation
import Synchronization

/// A scripted `RuntimeBackend` for SwiftUI previews and tests. Performs no I/O.
///
/// Scenarios are keyed by request case name and apply to queries as well as operations.
/// Requests are recorded in the order `send` was called, not in scheduler order. Each `send`
/// binds its scenario and any seeded operation id at the moment it is called, so a later
/// `script` or `useOperationID` cannot change a request already sent. It records the request
/// and emits `accepted` under a turn ticket; the rest of the scenario runs concurrently so a
/// hanging operation never blocks the `cancelOperation` that ends it.
public actor FakeRuntimeBackend: RuntimeBackend {
    public enum Scenario: Sendable {
        /// `accepted`, the given phases, an optional status, then `completed`. For queries, the
        /// normal reply.
        case succeed(phases: [ProgressPhase] = [], status: EnvironmentStatus? = nil)
        /// `accepted`, the given phases, then `failed(error)`. For queries, `failed` with a fresh id.
        case fail(after: [ProgressPhase] = [], error: GuesthouseError)
        /// `accepted`, then nothing until the consumer cancels or sends `cancelOperation` for
        /// the id; the fake then ends with `failed(.canceled)`.
        case hang
        /// `accepted`, the given phases, then the stream throws `RuntimeConnectionInterrupted`.
        /// For queries, the stream throws immediately.
        case disconnect(after: [ProgressPhase] = [])
    }

    /// Pause between events, so previews can show progress.
    public var delay: Duration
    public private(set) var receivedRequests: [RuntimeRequest] = []

    /// Read synchronously by `send`, so configuration and requests keep their call order.
    private struct Configuration: Sendable {
        var scenarios: [String: Scenario] = [:]
        var pendingOperationIDs: [String: OperationID] = [:]
        var nextTicket: UInt64 = 0
        /// Cancellations reserved by `send` before any producer can run, so an explicit
        /// request is never mistaken for a consumer that merely stopped listening. Counted
        /// per id: overlapping requests for one operation each hold their own reservation,
        /// so releasing one does not speak for the others.
        var explicitCancellations: [OperationID: Int] = [:]
    }

    /// What one `send` bound when it was called.
    private struct Binding: Sendable {
        let scenario: Scenario
        let seededOperationID: OperationID?
    }

    private nonisolated let configuration = Mutex(Configuration())
    private var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    private var environments: [DevelopmentEnvironment] = []
    private var versionInfo: RuntimeVersionInfo
    /// What `importXcode` reports, or `nil` for a rejected selection.
    private var xcodeCandidate: XcodeCandidate?
    private var canceledOperations: Set<OperationID> = []
    /// Where a recorded request falls in the order the requests were *made*, which is the order
    /// their turn tickets were taken in rather than the order they reached `receivedRequests`.
    ///
    /// A consumer cancellation a reservation suppresses is given a key in the same space at the
    /// moment it happens, and replaying it later inserts it by that key. An index into the log
    /// is not enough: a request that took an earlier ticket may still be waiting for its turn,
    /// so it is not in the log yet, and the cancellation would be replayed in front of a request
    /// that was really sent before it. The doubling makes room for the suppressed ones — a
    /// request's key is odd, a suppression's is even — so a cancellation seen while ticket `t`
    /// was still unissued sorts ahead of the request that goes on to take it, and `suppression`
    /// keeps two seen between the same pair of requests in the order they were seen.
    private struct LogKey: Comparable {
        let ticket: UInt64
        let suppression: UInt64

        static func < (a: LogKey, b: LogKey) -> Bool {
            (a.ticket, a.suppression) < (b.ticket, b.suppression)
        }

        static func request(_ ticket: UInt64) -> LogKey { LogKey(ticket: 2 * ticket + 1, suppression: 0) }
    }

    private var receivedKeys: [LogKey] = []
    private var nextSuppression: UInt64 = 0
    /// Consumer cancellations a reservation kept out of `receivedRequests`, each with the log
    /// slot it reserved when it happened. They are replayed in that slot if the reserved request
    /// turns out never to have taken effect.
    private var suppressedCancellations: [OperationID: LogKey] = [:]

    private var servingTicket: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    public init(delay: Duration = .zero, versionInfo: RuntimeVersionInfo = RuntimeVersionInfo(serviceVersion: "0.0.0", serviceBuild: "fake", tart: .init(version: "2.36.0", verified: true))) {
        self.delay = delay
        self.versionInfo = versionInfo
    }

    // MARK: - Scripting

    /// Sets the scenario for every request whose `caseName` matches, for example `"startEnvironment"`.
    public func script(_ caseName: String, _ scenario: Scenario) {
        configuration.withLock { $0.scenarios[caseName] = scenario }
    }

    /// The status returned for `environmentStatus(id)`.
    public func setStatus(_ status: EnvironmentStatus) {
        statuses[status.environmentID] = status
    }

    /// The environments returned for `listEnvironments`.
    public func setEnvironments(_ environments: [DevelopmentEnvironment]) {
        self.environments = environments
    }

    public func setVersionInfo(_ info: RuntimeVersionInfo) {
        versionInfo = info
    }

    /// The candidate `importXcode` replies with; `nil` makes it reply `xcodeSelectionRejected`.
    public func setXcodeCandidate(_ candidate: XcodeCandidate?) {
        xcodeCandidate = candidate
    }

    public func status(of id: EnvironmentID) -> EnvironmentStatus? {
        statuses[id]
    }

    /// Makes the next request with this case name use `id` as its operation id, so a preview
    /// or test can correlate a pre-seeded `EnvironmentStatus.inFlightOperation` with the events.
    public func useOperationID(_ id: OperationID, forNext caseName: String) {
        configuration.withLock { $0.pendingOperationIDs[caseName] = id }
    }

    // MARK: - RuntimeBackend

    public nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        // Ticket and binding are taken under one lock, so two concurrent sends cannot swap
        // the seeded id intended for the earlier one.
        let (ticket, binding) = configuration.withLock { configuration in
            defer { configuration.nextTicket += 1 }
            if case .cancelOperation(let id) = request { configuration.explicitCancellations[id, default: 0] += 1 }
            return (configuration.nextTicket, Binding(
                scenario: configuration.scenarios[request.caseName] ?? .succeed(),
                seededOperationID: configuration.pendingOperationIDs.removeValue(forKey: request.caseName)
            ))
        }
        return AsyncThrowingStream { continuation in
            let task = Task { await self.run(request, ticket: ticket, binding: binding, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: RuntimeRequest, ticket: UInt64, binding: Binding, _ continuation: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation) async {
        await waitForTurn(ticket)
        record(request, at: .request(ticket))
        let scenario = binding.scenario

        switch request {
        case .runtimeVersion, .environmentStatus, .listEnvironments, .importXcode:
            advanceTurn()
            await pause()
            switch scenario {
            case .disconnect:
                continuation.finish(throwing: RuntimeConnectionInterrupted())
            case .fail(_, let error):
                continuation.yield(.failed(OperationID(), error))
                continuation.finish()
            case .hang:
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                continuation.finish(throwing: RuntimeConnectionInterrupted())
            case .succeed:
                switch request {
                case .environmentStatus(let id):
                    continuation.yield(.status(statuses[id] ?? EnvironmentStatus(environmentID: id, vm: .notFound, readiness: .checking)))
                case .listEnvironments:
                    continuation.yield(.environments(environments))
                case .importXcode:
                    // One-shot validation: the service answers a candidate or a selection error.
                    if let xcodeCandidate {
                        continuation.yield(.xcodeCandidate(xcodeCandidate))
                    } else {
                        continuation.yield(.failed(OperationID(), .xcodeSelectionRejected(.notXcode)))
                    }
                default:
                    continuation.yield(.runtimeVersion(versionInfo))
                }
                continuation.finish()
            }
            return

        case .cancelOperation(let id):
            advanceTurn()
            await pause()
            switch scenario {
            case .disconnect:
                // The request never took effect: the reservation is released, so a later
                // consumer-driven cancellation is recorded as the request it is.
                releaseReservation(of: id)
                continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
            case .fail(_, let error):
                releaseReservation(of: id)
                continuation.yield(.failed(id, error))
                continuation.finish()
            case .hang:
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                releaseReservation(of: id)
                continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
            case .succeed(_, let status):
                canceledOperations.insert(id)
                // This request took effect, so a consumer cancellation its reservation
                // suppressed stays suppressed even if another reserved request later fails.
                suppressedCancellations.removeValue(forKey: id)
                // A scripted post-cancellation status is applied first: the canceled
                // operation is no longer in flight for any environment, including one the
                // scripted status still names.
                if let status { statuses[status.environmentID] = status }
                clearInFlight(id)
                continuation.finish()
            }
            return

        case .startEnvironment, .stopEnvironment:
            break
        }

        let id = binding.seededOperationID ?? OperationID()
        // `accepted` means journaled and in flight, so the environment's stored status names
        // the operation from here until its terminal event, whether or not a caller seeded it.
        markInFlight(id, for: request)
        continuation.yield(.accepted(id))
        advanceTurn()

        switch scenario {
        case .succeed(let phases, let status):
            for phase in phases {
                guard await progress(id, phase, continuation) else { return }
            }
            await pause()
            // Cancellation is re-checked after the pause: an operation cancelled while the
            // fake was waiting must not report success, and it stays in flight until its own
            // terminal event, so a status query never sees an idle environment mid-stream.
            guard !cancelled(id, continuation) else { return }
            if let status {
                // The scripted status is stored with the operation still in flight, since it
                // does not end until `completed`: a status query during the pause below must
                // not see an idle environment.
                var stored = status
                stored.inFlightOperation = status.inFlightOperation ?? id
                statuses[status.environmentID] = stored
                // The stored copy is what is emitted, so a consumer applying stream events
                // and a status query agree about the operation still being in flight.
                continuation.yield(.status(stored))
                await pause()
                guard !cancelled(id, continuation) else { return }
            }
            clearInFlight(id)
            continuation.yield(.completed(id))
            continuation.finish()

        case .fail(let phases, let error):
            for phase in phases {
                guard await progress(id, phase, continuation) else { return }
            }
            await pause()
            guard !cancelled(id, continuation) else { return }
            // A failed operation is no longer in flight for any environment.
            clearInFlight(id)
            continuation.yield(.failed(id, error))
            continuation.finish()

        case .hang:
            while !Task.isCancelled, !canceledOperations.contains(id) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            recordImplicitCancellation(of: id)
            clearInFlight(id)
            continuation.yield(.failed(id, .canceled))
            continuation.finish()

        case .disconnect(let phases):
            for phase in phases {
                guard await progress(id, phase, continuation) else { return }
            }
            await pause()
            // A consumer that went away during the pause cancelled the operation, exactly as
            // in the other branches: it is recorded and ends as canceled rather than leaving
            // a seeded operation in flight behind a connection loss nobody is listening for.
            guard !cancelled(id, continuation) else { return }
            continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
        }
    }

    /// Emits one phase. Returns false if the consumer or a `cancelOperation` canceled meanwhile.
    private func progress(_ id: OperationID, _ phase: ProgressPhase, _ continuation: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation) async -> Bool {
        await pause()
        guard !cancelled(id, continuation) else { return false }
        continuation.yield(.progress(id, phase))
        return true
    }

    /// Whether the operation was cancelled, by the consumer or by a `cancelOperation`. Ends
    /// the stream with `canceled` when it was, so every suspension point answers the same way.
    private func cancelled(_ id: OperationID, _ continuation: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation) -> Bool {
        guard Task.isCancelled || canceledOperations.contains(id) else { return false }
        recordImplicitCancellation(of: id)
        // A cancelled operation is no longer in flight either, however it was cancelled.
        clearInFlight(id)
        continuation.yield(.failed(id, .canceled))
        continuation.finish()
        return true
    }

    /// Undoes the reservation `send` made for a cancellation request that did not succeed.
    ///
    /// A consumer cancellation the reservation suppressed meanwhile is recorded now: the
    /// request that stood in for it never took effect, so the consumer's own cancellation is
    /// the only one that happened and `receivedRequests` must show it.
    private func releaseReservation(of id: OperationID) {
        let outstanding = configuration.withLock { configuration -> Int in
            guard let held = configuration.explicitCancellations[id] else { return 0 }
            configuration.explicitCancellations[id] = held > 1 ? held - 1 : nil
            return held - 1
        }
        // Another reserved request for the same id is still pending: that one, not the
        // consumer, stands in for the cancellation until it too fails to take effect.
        guard outstanding <= 0 else { return }
        guard let slot = suppressedCancellations.removeValue(forKey: id) else { return }
        canceledOperations.insert(id)
        // Replayed in the slot it reserved rather than appended here: the reservation can be
        // released long after the consumer went away, and appending would show the cancellation
        // behind every request that was really sent after it.
        record(.cancelOperation(id), at: slot)
    }

    /// Puts a request in the log in the order it was made, which for everything but a replayed
    /// cancellation is simply the end.
    private func record(_ request: RuntimeRequest, at key: LogKey) {
        let index = receivedKeys.firstIndex { key < $0 } ?? receivedRequests.count
        receivedRequests.insert(request, at: index)
        receivedKeys.insert(key, at: index)
    }

    private func clearInFlight(_ id: OperationID) {
        for (environment, status) in statuses where status.inFlightOperation == id {
            statuses[environment]?.inFlightOperation = nil
        }
    }

    /// Names the operation in the environment's stored status, when one is stored. A fake with
    /// no status for that environment stays silent rather than inventing VM and readiness state.
    private func markInFlight(_ id: OperationID, for request: RuntimeRequest) {
        switch request {
        case .startEnvironment(let environment, _), .stopEnvironment(let environment, _), .importXcode(let environment, _):
            statuses[environment]?.inFlightOperation = id
        case .runtimeVersion, .listEnvironments, .environmentStatus, .cancelOperation:
            break
        }
    }

    /// A consumer that stops listening counts as one cancel request, unless the operation was
    /// already canceled explicitly: `receivedRequests` then still mirrors real `send` calls.
    /// The explicit request reserves the id in `send`, before any producer can run, so the
    /// two never race, and the reservation is released again if that request fails.
    ///
    /// The synthetic request takes a ticket like any other, so it cannot overtake a `send`
    /// that was made before the consumer went away.
    private func recordImplicitCancellation(of id: OperationID) {
        let explicit = configuration.withLock { $0.explicitCancellations[id] != nil }
        guard Task.isCancelled, !canceledOperations.contains(id) else { return }
        // The reserved request may still fail, so what it suppressed is remembered rather
        // than dropped: releasing the reservation replays it, in the slot reserved here. The
        // slot is read from the ticket counter rather than taken from it — a ticket has to be
        // served for the queue to advance, and one held for the lifetime of a hanging
        // reservation would stall every later request — so it names the moment before the next
        // request is sent and after every request that has already taken its ticket, whether or
        // not that request has reached the log yet.
        if explicit {
            guard suppressedCancellations[id] == nil else { return }
            defer { nextSuppression += 1 }
            suppressedCancellations[id] = LogKey(
                ticket: 2 * configuration.withLock { $0.nextTicket },
                suppression: nextSuppression
            )
            return
        }
        canceledOperations.insert(id)
        let ticket = nextTicket()
        Task { await self.appendCancellation(of: id, ticket: ticket) }
    }

    private nonisolated func nextTicket() -> UInt64 {
        configuration.withLock { configuration -> UInt64 in
            defer { configuration.nextTicket += 1 }
            return configuration.nextTicket
        }
    }

    private func appendCancellation(of id: OperationID, ticket: UInt64) async {
        await waitForTurn(ticket)
        record(.cancelOperation(id), at: .request(ticket))
        advanceTurn()
    }

    private func waitForTurn(_ ticket: UInt64) async {
        while servingTicket != ticket {
            await withCheckedContinuation { continuation in
                waiters[ticket] = continuation
                if servingTicket == ticket, let waiter = waiters.removeValue(forKey: ticket) {
                    waiter.resume()
                }
            }
        }
    }

    private func advanceTurn() {
        servingTicket += 1
        waiters.removeValue(forKey: servingTicket)?.resume()
    }

    private func pause() async {
        guard delay > .zero else { return }
        try? await Task.sleep(for: delay)
    }
}
