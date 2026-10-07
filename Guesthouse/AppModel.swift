import Foundation
import GuesthouseCore
import Observation

/// App-owned checks survive window closure (MVP-PLAN.md §§2–3, retained #75).
/// Saved records and observed status remain separate; neither implies capability readiness.
@MainActor @Observable
final class AppModel {
    nonisolated enum CheckState: Equatable, Sendable {
        case checkingEnvironment
        case checked
        case metadataUnavailable(RuntimeSavedStateStatus)
        case unavailable(GuesthouseError)
        case interrupted(RuntimeSessionFailure.Cause)
    }

    private(set) var checkState: CheckState = .checkingEnvironment
    private(set) var environments: [DevelopmentEnvironment] = []
    private(set) var statuses: [EnvironmentID: EnvironmentStatus] = [:]
    /// Previously observed runtime identities, not proof that an operation is still running.
    /// Failed checks and inventory omissions cannot erase these inspection obligations.
    private(set) var recoveredOperations: [EnvironmentID: OperationID] = [:]
    private(set) var isChecking = false
    private(set) var isStarting = false
    private(set) var startingEnvironment: EnvironmentID?
    private(set) var startCanCancel = false
    private(set) var startOperationID: OperationID?
    private(set) var startCancellationRequested = false
    private(set) var startCancellationReplyReceived = false
    private(set) var startCancellationFailure: StartOperation.Failure?
    @ObservationIgnored private var cancelStartTask: Task<Void, Never>?
    private(set) var startMayHaveMutated = false
    var startNeedsInspection: Bool { startMayHaveMutated && (isStarting || startFailure != nil) }
    private(set) var startPhase: ProgressPhase?
    private(set) var startDiagnostics = DiagnosticLog(capacity: 256)
    private(set) var sessionDiagnostics = DiagnosticLog(capacity: 500)
    private(set) var startFailureDismissed = false
    private(set) var startFailure: StartOperation.Failure?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    let backend: any RuntimeBackend
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var checksReservedForQuit = false

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
        if let startTask { return startTask }
        if checksReservedForQuit { return checkTask ?? Task {} }
        return startCheck(clearStartFailure: true)
    }

    func reserveChecksForQuit(_ reserved: Bool) { checksReservedForQuit = reserved }

    /// A pre-existing menu check must drain, then Quit obtains a new snapshot of its own.
    func checkForQuit() async {
        // Quit reserves new work immediately, then retains any accepted Start's outcome.
        if let startTask { await startTask.value }
        if let checkTask { await checkTask.value }
        guard !Task.isCancelled else { return }
        await startCheck().value
    }

    func canStart(_ id: EnvironmentID) -> Bool {
        guard backend.allowsEnvironmentStart, startCancellationFailure == nil,
              !isStarting && !isChecking && !checksReservedForQuit && startEligible(id) else { return false }
        if let startFailure {
            // One runtime writer and one presented Start result. Do not overwrite another
            // environment's failure; an explicit successful Check clears it first.
            guard startingEnvironment == id else { return false }
            if case .runtime(let error) = startFailure { return error.isRetryable }
            return false // Unknown outcome requires an explicit inspection, never a plain retry.
        }
        return true
    }

    private func startEligible(_ id: EnvironmentID) -> Bool {
        guard recoveredOperations.isEmpty, checkState == .checked, environments.contains(where: { $0.id == id }),
              statuses[id]?.vm == .stopped else { return false }
        if case .needsAttention = statuses[id]?.readiness { return false }
        return statuses.values.allSatisfy {
            if case .uncertain = $0.vm { return false }
            return $0.inFlightOperation == nil
        }
    }

    /// The app owns the task across window closure. Duplicate starts are refused and checks join existing work;
    /// Quit waits for its outcome. Every click inspects again before issuing one mutation.
    @discardableResult
    func startEnvironment(_ id: EnvironmentID) -> Task<Void, Never>? {
        guard canStart(id) else { return nil }
        return beginStart(id)
    }

    func canRetryStart(_ id: EnvironmentID) -> Bool {
        backend.allowsEnvironmentStart && startCancellationFailure == nil
            && recoveredOperations.isEmpty
            && !startNeedsInspection && !isStarting && !isChecking && !checksReservedForQuit && startingEnvironment == id
            && startFailure?.recoveryActions.contains(.retry) == true
    }

    /// Retry is an explicit new attempt, including a new inspection. It is never offered for
    /// an unknown outcome and does not require pre-existing status after a failed query.
    @discardableResult
    func retryStart(_ id: EnvironmentID) -> Task<Void, Never>? {
        guard canRetryStart(id) else { return nil }
        return beginStart(id)
    }

    private func beginStart(_ id: EnvironmentID) -> Task<Void, Never> {
        isStarting = true; startingEnvironment = id; startPhase = nil; startFailure = nil; startFailureDismissed = false
        startOperationID = nil; startCanCancel = true; startCancellationRequested = false; startCancellationReplyReceived = false; startCancellationFailure = nil
        startMayHaveMutated = false
        let work = Task { [weak self] in
            guard let self else { return }
            defer { isStarting = false; startTask = nil; startPhase = nil; startOperationID = nil; startCanCancel = false }
            await startCheck().value
            guard !startCancellationRequested else { startFailure = .runtime(.canceled); return }
            guard !checksReservedForQuit else { startFailure = .quitPending; return }
            guard startEligible(id) else {
                startFailure = checkState == .checked ? .stateChanged : .check(checkState); return
            }
            invalidateStatusForMutation()
            // Mark before dispatch, including a lost reply before acceptance. A failed
            // pre-Start query never sent a mutation and needs no target reconciliation.
            startMayHaveMutated = true
            let result = await StartOperation.run(id, backend: backend,
                accepted: { [weak self] operation in
                    self?.startDiagnostics.removeAll()
                    self?.startOperationID = operation
                    if self?.startCancellationRequested == true { self?.sendStartCancellation(operation) }
                }, progress: { [weak self] phase in self?.startPhase = phase },
                diagnostic: { [weak self] event in
                    if let event = self?.recordDiagnostic(event, for: id), self?.startOperationID?.uuid == event.operationID {
                        // Refusals before acceptance belong to session history. Keep the last
                        // accepted attempt's log/counts intact until a new Start is accepted.
                        self?.startDiagnostics.append(event)
                    }
                })
            startFailure = result.failure
            startMayHaveMutated = result.mayHaveMutated
            startCanCancel = false
            // A target terminal does not settle the cancellation request. Keep its consumer
            // alive through the actual reply/connection failure before admitting new work.
            await cancelStartTask?.value
            cancelStartTask = nil
            // A terminal event is not a live state query. Unknown outcomes are inspected,
            // never retried, and remain visible even if the following check succeeds.
            await startCheck().value
            if startFailure == nil {
                if checkState != .checked { startFailure = .inspectionAfterStart(checkState) }
                else if statuses[id]?.vm != .running { startFailure = .notRunning }
            }
        }
        startTask = work
        return work
    }

    /// Keep consuming the target. A cancellation acknowledgement is not its terminal event.
    func cancelStart() {
        guard isStarting, startCanCancel, !startCancellationRequested else { return }
        startCancellationRequested = true; startCancellationReplyReceived = false; startCancellationFailure = nil
        if let startOperationID { sendStartCancellation(startOperationID) }
    }

    private func sendStartCancellation(_ operation: OperationID) {
        guard cancelStartTask == nil else { return }
        cancelStartTask = Task { [weak self, backend] in
            let result = await StartOperation.cancel(operation, backend: backend)
            guard !Task.isCancelled, let self, isStarting, startOperationID == operation else { return }
            startCancellationFailure = result.failure
            cancelStartTask = nil
            // A settled refusal permits another explicit cancellation request for this same
            // observed target. A successful acknowledgement still waits for the target.
            if result.retryAllowed { startCancellationRequested = false }
            startCancellationReplyReceived = true
        }
    }

    /// Operation consumers validate acceptance/identity before calling. Attribute an omitted
    /// environment to its known target so selection cannot leak another environment's activity.
    @discardableResult
    func recordDiagnostic(_ event: DiagnosticEvent, for environment: EnvironmentID) -> DiagnosticEvent? {
        guard DiagnosticIdentity.matches(event, environment: environment) else { return nil }
        let scoped = DiagnosticEvent(operation: event.operation, outcome: event.outcome,
            operationID: event.operationID, environmentID: environment)
        sessionDiagnostics.append(scoped)
        return scoped
    }

    /// Dismissing presentation cannot clear uncertainty or permit a new mutation.
    func dismissStartFailure() { startFailureDismissed = true }

    /// A settled cancellation failure stays visible until acknowledged. This only dismisses
    /// its message; the target's result and uncertainty remain independently retained.
    func dismissStartCancellationFailure() {
        guard !isStarting else { return }
        startCancellationFailure = nil
    }

    func invalidateStatusForMutation() {
        generation = UUID()
        statuses = [:]
        checkState = .checkingEnvironment
    }

    private func startCheck(clearStartFailure: Bool = false) -> Task<Void, Never> {
        if let checkTask { return checkTask }
        let current = UUID()
        generation = current
        isChecking = true
        checkState = .checkingEnvironment
        statuses = [:]
        let retainedTarget = clearStartFailure && startNeedsInspection ? startingEnvironment : nil
        var retainedIDs = Set(recoveredOperations.keys)
        if let retainedTarget { retainedIDs.insert(retainedTarget) }
        checkTask = Task { [weak self, backend] in
            let result = await Self.read(backend, retainedIDs: retainedIDs) { [weak self] status in
                guard let self, self.generation == current, !Task.isCancelled,
                      let operation = status.inFlightOperation else { return }
                // Preserve a valid individual observation even if a later query fails.
                // Never publish partial readiness or clear an obligation from partial reads.
                self.recoveredOperations[status.environmentID] = operation
            }
            guard let self else { return }
            defer { self.isChecking = false; self.checkTask = nil }
            guard self.generation == current else { return }
            guard !Task.isCancelled else { self.checkState = .unavailable(.canceled); return }
            switch result {
            case .success(let snapshot):
                self.environments = snapshot.environments
                self.statuses = snapshot.statuses
                self.checkState = .checked
                for id in Array(self.recoveredOperations.keys) {
                    guard snapshot.environments.contains(where: { $0.id == id }),
                          let status = snapshot.statuses[id], status.inFlightOperation == nil else { continue }
                    // Missing/unlisted/uncertain state still requires reconciliation/repair.
                    // Only a complete current check of a listed, inspected VM can clear this.
                    switch status.vm {
                    case .stopped, .running: self.recoveredOperations.removeValue(forKey: id)
                    case .notFound, .uncertain: break
                    }
                }
                if clearStartFailure, !self.startMayHaveMutated {
                    self.startFailure = nil
                    self.startingEnvironment = nil
                } else if clearStartFailure, let id = self.startingEnvironment, let status = snapshot.statuses[id], status.inFlightOperation == nil {
                    switch status.vm {
                    case .stopped, .notFound: self.startFailure = nil
                    case .running:
                        // A live target missing from saved inventory still needs repair.
                        if snapshot.environments.contains(where: { $0.id == id }) { self.startFailure = nil }
                    case .uncertain: break
                    }
                }
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

    private static func read(_ backend: any RuntimeBackend, retainedIDs: Set<EnvironmentID>,
                             observed: (EnvironmentStatus) -> Void) async -> Result<Snapshot, ReadFailure> {
        do {
            guard case .environments(let inventory) = try await reply(to: .listEnvironments, from: backend),
                  inventory.isValid else { throw ReadFailure.runtime(.invalidRuntimeReply(.malformed)) }
            let environments: [DevelopmentEnvironment]
            switch inventory {
            case .unavailable(let state): throw ReadFailure.metadata(state)
            case .available(let records): environments = records
            }
            var statuses: [EnvironmentID: EnvironmentStatus] = [:]
            var requestedIDs = environments.map(\.id)
            requestedIDs += retainedIDs.subtracting(requestedIDs).sorted { $0.uuid.uuidString < $1.uuid.uuidString }
            for id in requestedIDs {
                try Task.checkCancellation()
                guard case .status(let status) = try await reply(to: .environmentStatus(id), from: backend),
                      status.environmentID == id else {
                    throw ReadFailure.runtime(.invalidRuntimeReply(.malformed))
                }
                observed(status)
                statuses[id] = status
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
