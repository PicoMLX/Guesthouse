import Foundation
import Synchronization

/// A scripted `RuntimeBackend` for SwiftUI previews and tests. Performs no I/O.
///
/// Scenarios are keyed by request case name and apply to queries as well as operations.
/// Requests are recorded in the order `send` was called, not in scheduler order. Each `send`
/// records the request and emits `accepted` under a turn ticket; the rest of the scenario
/// runs concurrently so a hanging operation never blocks the `cancelOperation` that ends it.
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

    private var scenarios: [String: Scenario] = [:]
    private var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    private var versionInfo: RuntimeVersionInfo
    private var canceledOperations: Set<OperationID> = []

    private nonisolated let ticketCounter = Mutex<UInt64>(0)
    private var servingTicket: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    public init(delay: Duration = .zero, versionInfo: RuntimeVersionInfo = RuntimeVersionInfo(serviceVersion: "0.0.0", serviceBuild: "fake", tart: .init(version: "2.36.0", verified: true))) {
        self.delay = delay
        self.versionInfo = versionInfo
    }

    // MARK: - Scripting

    /// Sets the scenario for every request whose `caseName` matches, for example `"startEnvironment"`.
    public func script(_ caseName: String, _ scenario: Scenario) {
        scenarios[caseName] = scenario
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

    // MARK: - RuntimeBackend

    public nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        let ticket = ticketCounter.withLock { counter in
            defer { counter += 1 }
            return counter
        }
        return AsyncThrowingStream { continuation in
            let task = Task { await self.run(request, ticket: ticket, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: RuntimeRequest, ticket: UInt64, _ continuation: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation) async {
        await waitForTurn(ticket)
        receivedRequests.append(request)
        let scenario = scenarios[request.caseName] ?? .succeed()

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
            canceledOperations.insert(id)
            advanceTurn()
            continuation.finish()
            return

        case .startEnvironment, .stopEnvironment, .importXcode:
            break
        }

        let id = OperationID()
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
            if Task.isCancelled { receivedRequests.append(.cancelOperation(id)) }
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
            if Task.isCancelled { receivedRequests.append(.cancelOperation(id)) }
            continuation.yield(.failed(id, .canceled))
            continuation.finish()
            return false
        }
        continuation.yield(.progress(id, phase))
        return true
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
