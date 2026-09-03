import Foundation

/// A scripted `RuntimeBackend` for SwiftUI previews and tests. Performs no I/O.
///
/// Scenarios are keyed by request case name. Each `send` records the request, so tests can
/// assert what the GUI asked for, including the `cancelOperation` the fake records when a
/// consumer stops reading a hanging operation.
public actor FakeRuntimeBackend: RuntimeBackend {
    public enum Scenario: Sendable {
        /// `accepted`, the given phases, an optional status, then `completed`.
        case succeed(phases: [ProgressPhase] = [], status: EnvironmentStatus? = nil)
        /// `accepted`, the given phases, then `failed(error)`.
        case fail(after: [ProgressPhase] = [], error: GuesthouseError)
        /// `accepted`, then nothing until the consumer cancels; the fake then records
        /// `cancelOperation` and ends with `failed(.canceled)`.
        case hang
        /// `accepted`, the given phases, then the stream throws `RuntimeConnectionInterrupted`.
        case disconnect(after: [ProgressPhase] = [])
    }

    /// Pause between events, so previews can show progress.
    public var delay: Duration
    public private(set) var receivedRequests: [RuntimeRequest] = []

    private var scenarios: [String: Scenario] = [:]
    private var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    private var versionInfo: RuntimeVersionInfo

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
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(request, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: RuntimeRequest, _ continuation: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation) async {
        receivedRequests.append(request)

        switch request {
        case .runtimeVersion:
            await pause()
            continuation.yield(.runtimeVersion(versionInfo))
            continuation.finish()
            return
        case .environmentStatus(let id):
            await pause()
            continuation.yield(.status(statuses[id] ?? EnvironmentStatus(environmentID: id, vm: .notFound, readiness: .checking)))
            continuation.finish()
            return
        case .cancelOperation:
            continuation.finish()
            return
        case .startEnvironment, .stopEnvironment, .importXcode:
            break
        }

        let id = OperationID()
        let scenario = scenarios[request.caseName] ?? .succeed()
        continuation.yield(.accepted(id))

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
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            receivedRequests.append(.cancelOperation(id))
            continuation.yield(.failed(id, .canceled))
            continuation.finish()

        case .disconnect(let phases):
            for phase in phases {
                guard await progress(id, phase, continuation) else { return }
            }
            continuation.finish(throwing: RuntimeConnectionInterrupted(operationID: id))
        }
    }

    /// Emits one phase. Returns false if the consumer canceled meanwhile.
    private func progress(_ id: OperationID, _ phase: ProgressPhase, _ continuation: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation) async -> Bool {
        await pause()
        if Task.isCancelled {
            receivedRequests.append(.cancelOperation(id))
            continuation.yield(.failed(id, .canceled))
            continuation.finish()
            return false
        }
        continuation.yield(.progress(id, phase))
        return true
    }

    private func pause() async {
        guard delay > .zero else { return }
        try? await Task.sleep(for: delay)
    }
}
