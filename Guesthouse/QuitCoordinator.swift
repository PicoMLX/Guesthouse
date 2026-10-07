import Foundation
import GuesthouseCore
import Observation

/// Stop-before-Quit coordination, separate from window lifetime (MVP-PLAN.md §2, #27).
/// Production VM mutations remain refused until the runtime's provider integration is accepted.
@MainActor @Observable
final class QuitCoordinator {
    nonisolated enum Failure: Error, Equatable {
        case check(AppModel.CheckState)
        case ownership(EnvironmentID, EnvironmentStatus.UncertaintyReason)
        case unsettled(OperationID)
        case stop(GuesthouseError)
        case interrupted(RuntimeSessionFailure)
        case stillRunning
    }
    nonisolated enum Flow: Equatable, Sendable {
        case idle, confirming, checking, terminating
        case stopping(EnvironmentID, ProgressPhase?, force: Bool)
        case failed(Failure)
    }
    private(set) var flow: Flow = .idle
    private(set) var cancelRequested = false
    let model: AppModel
    let warning = "Stopping a development Mac interrupts any Codex task running in it. Guesthouse cannot see those tasks; finish them first."
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempt = UUID()
    @ObservationIgnored private var gracefulFailures: [EnvironmentID: UUID] = [:]
    @ObservationIgnored private var unconfirmedEnvironments: Set<EnvironmentID> = []
    @ObservationIgnored private let terminationDecision: @MainActor (Bool) -> Void

    init(model: AppModel, terminationDecision: @escaping @MainActor (Bool) -> Void) {
        self.model = model; self.terminationDecision = terminationDecision
    }
    isolated deinit { task?.cancel() }

    func requestQuit() -> Bool {
        if flow == .terminating { return true }
        if flow == .idle {
            gracefulFailures = [:]
            unconfirmedEnvironments = Set(model.environments.map(\.id))
            if model.startNeedsInspection, let target = model.startingEnvironment {
                unconfirmedEnvironments.insert(target)
            }
            model.reserveChecksForQuit(true)
            flow = .confirming
        }
        return false
    }

    @discardableResult
    func confirmStopAndQuit() -> Task<Void, Never>? {
        guard flow == .confirming else { return nil }
        gracefulFailures = [:]
        return begin(force: false)
    }

    var canForceStop: Bool {
        guard case .failed(.stop(.guestShutdownRefused(let id))) = flow,
              gracefulFailures[id] != nil, model.recoveredOperations.isEmpty, model.checkState == .checked,
              model.statuses[id]?.vm == .running, model.statuses[id]?.inFlightOperation == nil,
              model.statuses[id]?.runtimeInstanceID == gracefulFailures[id] else { return false }
        return true
    }

    /// Called only after the sheet's explicit unsaved-work warning and destructive consent.
    @discardableResult
    func forceStopAndQuit() -> Task<Void, Never>? {
        guard canForceStop else { return nil }
        return begin(force: true)
    }

    func cancelQuit() {
        switch flow {
        case .idle, .terminating: return
        case .stopping(_, let phase, let force):
            cancelRequested = true
            // Before a phase, during protected shutdown, or while forcing: retain the outcome.
            if !force, phase?.cancelable == true { task?.cancel() }
        default:
            task?.cancel()
            finishCancel()
        }
    }

    /// Inspection returns to confirmation; it never resumes a stop automatically.
    @discardableResult
    func inspectBeforeContinuing() -> Task<Void, Never>? {
        guard case .failed = flow else { return nil }
        let refusal: Failure?
        if case .failed(.stop(.guestShutdownRefused(let id))) = flow, gracefulFailures[id] != nil {
            refusal = .stop(.guestShutdownRefused(id))
        } else { refusal = nil }
        attempt = UUID(); let current = attempt
        flow = .checking
        task = Task { [weak self] in
            guard let self else { return }
            defer { if attempt == current { task = nil } }
            do {
                guard try await inspect(attempt: current) else { return }
                if case .stop(.guestShutdownRefused(let id))? = refusal, model.statuses[id]?.vm == .running,
                   model.statuses[id]?.runtimeInstanceID == gracefulFailures[id] {
                    flow = .failed(.stop(.guestShutdownRefused(id)))
                } else { flow = .confirming }
            } catch { if attempt == current { flow = .failed(error as? Failure ?? .stop(.invalidRuntimeReply(.malformed))) } }
        }
        return task
    }

    private func begin(force: Bool) -> Task<Void, Never> {
        attempt = UUID(); let current = attempt
        cancelRequested = false; flow = .checking
        let work = Task { [weak self] in
            guard let self else { return }
            await stopAfterInspection(force: force, attempt: current)
        }
        task = work
        return work
    }

    private func stopAfterInspection(force: Bool, attempt current: UUID) async {
        defer { if attempt == current { task = nil } }
        var attempted: Set<EnvironmentID> = []
        do {
            while try await inspect(attempt: current) {
                guard let environment = model.environments.first(where: { model.statuses[$0.id]?.vm == .running }) else {
                    flow = .terminating; terminationDecision(true); return
                }
                // At most two distinct targets per confirmed attempt. Never blindly repeat a
                // completed stop if its VM is running again, or chase an unbounded changing list.
                guard attempted.count < 2, attempted.insert(environment.id).inserted else { throw Failure.stillRunning }
                let instance = model.statuses[environment.id]?.runtimeInstanceID
                let useForce = force && instance != nil && gracefulFailures[environment.id] == instance
                if useForce { gracefulFailures.removeValue(forKey: environment.id) }
                model.invalidateStatusForMutation()
                try await stop(environment.id, force: useForce, instance: instance)
                gracefulFailures.removeValue(forKey: environment.id)
            }
        } catch {
            guard attempt == current else { return }
            if cancelRequested || Task.isCancelled { finishCancel(); return }
            let failure = error as? Failure ?? .stop(.invalidRuntimeReply(.malformed))
            if case .stop(.guestShutdownRefused(let id)) = failure, gracefulFailures[id] != nil {
                do {
                    // Consent is offered only after post-refusal inspection. Force itself also
                    // rechecks because the user may leave the warning open for some time.
                    guard try await inspect(attempt: current) else { return }
                    if model.statuses[id]?.vm != .running || model.statuses[id]?.runtimeInstanceID != gracefulFailures[id] {
                        gracefulFailures.removeValue(forKey: id); flow = .confirming; return
                    }
                } catch {
                    if attempt == current { flow = .failed(error as? Failure ?? .stop(.invalidRuntimeReply(.malformed))) }
                    return
                }
            }
            flow = .failed(failure)
        }
    }

    private func inspect(attempt current: UUID) async throws -> Bool {
        guard attempt == current else { return false }
        if cancelRequested || Task.isCancelled { finishCancel(); return false }
        flow = .checking
        await model.checkForQuit()
        guard attempt == current else { return false }
        if cancelRequested || Task.isCancelled { finishCancel(); return false }
        try validateInspection()
        return true
    }

    private func validateInspection() throws {
        guard model.checkState == .checked else { throw Failure.check(model.checkState) }
        if let id = model.recoveredOperations.keys.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }).first,
           let operation = model.recoveredOperations[id] { throw Failure.unsettled(operation) }
        // Quit may have retained a pending Start before its explicit refusal arrived.
        if !model.isStarting, !model.startMayHaveMutated, let target = model.startingEnvironment {
            unconfirmedEnvironments.remove(target)
        }
        // Saved cards are not live inventory. Omission cannot confirm a previously seen VM
        // stopped, including after a completed stop or while waiting for force consent.
        guard unconfirmedEnvironments.isSubset(of: Set(model.environments.map(\.id))) else {
            throw Failure.check(.unavailable(.invalidRuntimeReply(.malformed)))
        }
        for environment in model.environments {
            guard let status = model.statuses[environment.id] else { throw Failure.check(.unavailable(.invalidRuntimeReply(.malformed))) }
            if let operation = status.inFlightOperation { throw Failure.unsettled(operation) }
            if case .uncertain(let reason) = status.vm { throw Failure.ownership(environment.id, reason) }
        }
        unconfirmedEnvironments = Set(model.environments.compactMap {
            model.statuses[$0.id]?.vm == .running ? $0.id : nil
        })
    }

    private func stop(_ environment: EnvironmentID, force: Bool, instance: UUID?) async throws {
        flow = .stopping(environment, nil, force: force)
        var accepted: OperationID?
        var completed = false
        var failure: GuesthouseError?
        let mode: StopMode
        if force {
            guard let instance else { throw Failure.ownership(environment, .ownershipUnproven) }
            mode = .force(expectedInstanceID: instance)
        } else { mode = .graceful(deadline: .seconds(60)) }
        do {
            for try await event in model.backend.send(.stopEnvironment(environment, mode)) {
                try Task.checkCancellation()
                guard !completed else { throw malformed(accepted) }
                switch event {
                case .accepted(let id):
                    guard accepted == nil else { throw malformed(accepted) }; accepted = id
                case .progress(let id, let phase):
                    guard id == accepted else { throw malformed(accepted) }
                    flow = .stopping(environment, phase, force: force)
                case .status(let status):
                    guard accepted != nil, status.environmentID == environment,
                          status.inFlightOperation == nil || status.inFlightOperation == accepted else { throw malformed(accepted) }
                case .diagnostic(let event):
                    guard accepted != nil, event.operationID == accepted?.uuid,
                          DiagnosticIdentity.matches(event, environment: environment) else { throw malformed(accepted) }
                    model.recordDiagnostic(event, for: environment)
                case .completed(let id):
                    guard id == accepted else { throw malformed(accepted) }; completed = true
                case .failed(let id, let error):
                    guard accepted == nil || id == accepted else { throw malformed(accepted) }
                    failure = error; completed = true
                default: throw malformed(accepted)
                }
            }
            guard completed else { throw malformed(accepted) }
            if let failure {
                if !force, accepted != nil, let instance, failure == .guestShutdownRefused(environment) { gracefulFailures[environment] = instance }
                throw Failure.stop(failure)
            }
        } catch let error as Failure { throw error }
        catch let error as RuntimeSessionFailure { throw Failure.interrupted(error.contextualized(operationID: accepted, mayHaveMutated: true)) }
        catch let error as GuesthouseError { throw Failure.stop(error) }
        catch { throw malformed(accepted) }
    }

    private func malformed(_ id: OperationID?) -> Failure {
        .interrupted(.init(cause: .malformedResponse, operationID: id, mayHaveMutated: true))
    }

    private func finishCancel() {
        attempt = UUID(); cancelRequested = false; gracefulFailures = [:]; unconfirmedEnvironments = []
        flow = .idle; task = nil
        model.reserveChecksForQuit(false)
        terminationDecision(false)
        model.checkEnvironments()
    }
}
