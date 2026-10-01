import Foundation
import GuesthouseClientKit
import GuesthouseCore
import Observation

@MainActor @Observable final class HostPreflightModel {
    private(set) var outcome: RuntimeHostPreflightQuery.Outcome?
    private(set) var isChecking = false
    private(set) var cancellationRequested = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private let query: @Sendable () async -> RuntimeHostPreflightQuery.Outcome

    init(query: @escaping @Sendable () async -> RuntimeHostPreflightQuery.Outcome = { await RuntimeHostPreflightQuery.run() }) { self.query = query }
    var canProceed: Bool {
        guard !isChecking, case .success(let report) = outcome else { return false }
        return report.canProceed
    }
    @discardableResult func check() -> Task<Void, Never> {
        if let work { return work }
        outcome = nil; isChecking = true; cancellationRequested = false
        let task = Task { [weak self, query] in
            let result = await query()
            guard let self else { return }
            outcome = Task.isCancelled ? .failure(.canceled) : result
            isChecking = false; work = nil
        }
        work = task; return task
    }
    func cancel() {
        guard let work else { return }
        cancellationRequested = true; work.cancel(); outcome = .failure(.canceled)
        // Keep ownership until the query's connection and structured children drain.
    }
    func invalidate() { cancel(); outcome = nil }
}
