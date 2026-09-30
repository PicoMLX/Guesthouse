import Foundation
import GuesthouseCore
import Observation

/// App-owned checks survive window closure (MVP-PLAN.md §§2–3, retained #75).
/// Saved records and observed status remain separate; neither implies capability readiness.
@MainActor @Observable
final class AppModel {
    enum CheckState: Equatable {
        case checkingEnvironment
        case checked
        case metadataUnavailable(RuntimeSavedStateStatus)
        case unavailable(GuesthouseError)
        case interrupted(RuntimeSessionFailure.Cause)
    }

    private(set) var checkState: CheckState = .checkingEnvironment
    private(set) var environments: [DevelopmentEnvironment] = []
    private(set) var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    private(set) var isChecking = false
    let backend: any RuntimeBackend
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(backend: any RuntimeBackend) {
        self.backend = backend
        observation = Task { [weak self, backend] in
            for await cause in backend.connectionInterruptions {
                guard !Task.isCancelled else { return }
                self?.connectionInterrupted(cause)
            }
        }
    }

    isolated deinit {
        observation?.cancel()
        checkTask?.cancel()
    }

    /// Join an existing check instead of creating canceled requests that still occupy the
    /// service. The returned task belongs to the app model, never to a window's `.task`.
    @discardableResult
    func checkEnvironments() -> Task<Void, Never> {
        if let checkTask { return checkTask }
        let current = UUID()
        generation = current
        isChecking = true
        checkState = .checkingEnvironment
        statuses = [:]
        checkTask = Task { [weak self, backend] in
            let result = await Self.read(backend)
            guard let self else { return }
            defer { self.isChecking = false; self.checkTask = nil }
            guard self.generation == current else { return }
            guard !Task.isCancelled else { self.checkState = .unavailable(.canceled); return }
            switch result {
            case .success(let snapshot):
                self.environments = snapshot.environments
                self.statuses = snapshot.statuses
                self.checkState = .checked
            case .failure(.metadata(let state)): self.checkState = .metadataUnavailable(state)
            case .failure(.runtime(let error)): self.checkState = .unavailable(error)
            case .failure(.interrupted(let cause)): self.checkState = .interrupted(cause)
            }
        }
        return checkTask!
    }

    /// No automatic reconnection loop or mutation replay. A user check can establish fresh
    /// status after the current check drains. Even an already-answered late result is fenced.
    func connectionInterrupted(_ cause: RuntimeSessionFailure.Cause) {
        generation = UUID()
        statuses = [:]
        // Keep specific failure/recovery guidance when retirement follows that failure.
        switch checkState {
        case .metadataUnavailable, .unavailable, .interrupted: break
        case .checkingEnvironment, .checked: checkState = .interrupted(cause)
        }
    }

    private struct Snapshot {
        let environments: [DevelopmentEnvironment]
        let statuses: [EnvironmentID: EnvironmentStatus]
    }
    private enum ReadFailure: Error {
        case metadata(RuntimeSavedStateStatus), runtime(GuesthouseError), interrupted(RuntimeSessionFailure.Cause)
    }

    private static func read(_ backend: any RuntimeBackend) async -> Result<Snapshot, ReadFailure> {
        do {
            guard case .environments(let inventory) = try await reply(to: .listEnvironments, from: backend),
                  inventory.isValid else { throw ReadFailure.runtime(.invalidRuntimeReply(.malformed)) }
            let environments: [DevelopmentEnvironment]
            switch inventory {
            case .unavailable(let state): throw ReadFailure.metadata(state)
            case .available(let records): environments = records
            }
            var statuses: [EnvironmentID: EnvironmentStatus] = [:]
            for environment in environments {
                try Task.checkCancellation()
                guard case .status(let status) = try await reply(to: .environmentStatus(environment.id), from: backend),
                      status.environmentID == environment.id else {
                    throw ReadFailure.runtime(.invalidRuntimeReply(.malformed))
                }
                statuses[environment.id] = status
            }
            return .success(Snapshot(environments: environments, statuses: statuses))
        } catch let error as ReadFailure { return .failure(error) }
        catch let error as RuntimeSessionFailure { return .failure(.interrupted(error.cause)) }
        catch let error as GuesthouseError { return .failure(.runtime(error)) }
        catch is CancellationError { return .failure(.runtime(.canceled)) }
        catch { return .failure(.runtime(.invalidRuntimeReply(.malformed))) }
    }

    /// Empty, duplicate, progress and foreign replies cannot become a successful check.
    private static func reply(to request: RuntimeRequest, from backend: any RuntimeBackend) async throws -> RuntimeEvent {
        try Task.checkCancellation()
        var reply: RuntimeEvent?
        for try await event in backend.send(request) {
            try Task.checkCancellation()
            if case .failed(_, let error) = event { throw error }
            guard reply == nil else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
            switch (request, event) {
            case (.listEnvironments, .environments), (.environmentStatus, .status): reply = event
            default: throw GuesthouseError.invalidRuntimeReply(.malformed)
            }
        }
        guard let reply else { throw GuesthouseError.invalidRuntimeReply(.malformed) }
        return reply
    }
}
