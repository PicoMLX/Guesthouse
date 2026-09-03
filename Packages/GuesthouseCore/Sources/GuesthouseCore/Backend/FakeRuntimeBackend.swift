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
    }

    /// What one `send` bound when it was called.
    private struct Binding: Sendable {
        let scenario: Scenario
        let seededOperationID: OperationID?
    }

    private nonisolated let configuration = Mutex(Configuration())
    private var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    private var versionInfo: RuntimeVersionInfo
    private var canceledOperations: Set<OperationID> = []

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

    public func setVersionInfo(_ info: RuntimeVersionInfo) {
        versionInfo = info
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
        receivedRequests.append(request)
        let scenario = binding.scenario

        switch request {
        case .runtimeVersion, .environmentStatus:
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
                if case .environmentStatus(let id) = request {
                    continuation.yield(.status(statuses[id] ?? EnvironmentStatus(environmentID: id, vm: .notFound, readiness: .checking)))
                } else {
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
                continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
            case .fail(_, let error):
                continuation.yield(.failed(id, error))
                continuation.finish()
            case .hang:
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
            case .succeed(_, let status):
                canceledOperations.insert(id)
                // The canceled operation is no longer in flight for any environment, and a
                // scripted post-cancellation status is applied.
                clearInFlight(id)
                if let status { statuses[status.environmentID] = status }
                continuation.finish()
            }
            return

        case .startEnvironment, .stopEnvironment, .importXcode:
            break
        }

        let id = binding.seededOperationID ?? OperationID()
        continuation.yield(.accepted(id))
        advanceTurn()

        switch scenario {
        case .succeed(let phases, let status):
            for phase in phases {
                guard await progress(id, phase, continuation) else { return }
            }
            if let status {
                statuses[status.environmentID] = status
                continuation.yield(.status(status))
            }
            continuation.yield(.completed(id))
            continuation.finish()

        case .fail(let phases, let error):
            for phase in phases {
                guard await progress(id, phase, continuation) else { return }
            }
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
            continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
        }
    }

    /// Emits one phase. Returns false if the consumer or a `cancelOperation` canceled meanwhile.
    private func progress(_ id: OperationID, _ phase: ProgressPhase, _ continuation: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation) async -> Bool {
        await pause()
        if Task.isCancelled || canceledOperations.contains(id) {
            recordImplicitCancellation(of: id)
            continuation.yield(.failed(id, .canceled))
            continuation.finish()
            return false
        }
        continuation.yield(.progress(id, phase))
        return true
    }

    private func clearInFlight(_ id: OperationID) {
        for (environment, status) in statuses where status.inFlightOperation == id {
            statuses[environment]?.inFlightOperation = nil
        }
    }

    /// A consumer that stops listening counts as one cancel request, unless the operation was
    /// already canceled explicitly: `receivedRequests` then still mirrors real `send` calls.
    private func recordImplicitCancellation(of id: OperationID) {
        guard Task.isCancelled, !canceledOperations.contains(id) else { return }
        canceledOperations.insert(id)
        receivedRequests.append(.cancelOperation(id))
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
