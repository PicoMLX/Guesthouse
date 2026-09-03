import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor
@Suite struct RealRuntimeWiringTests {
    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func runningEnvironment(_ backend: FakeRuntimeBackend) async -> DevelopmentEnvironment {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        return environment
    }

    @Test func previewsAndTestsGetTheFakeBackend() {
        #expect(AppModel.makeBackend(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]) is FakeRuntimeBackend)
        #expect(AppModel.makeBackend(environment: ["GUESTHOUSE_FAKE_RUNTIME": "1"]) is FakeRuntimeBackend)
        #expect(AppModel.makeBackend(environment: [:]) is RuntimeClient)
    }

    @Test func aSecondStopWaitsForAVerifiedState() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.stop(environment.id)
        await waitUntil { model.operations.isEmpty && model.unknownOutcomes[environment.id] != nil }
        #expect(!model.canMutate(environment.id), "the state was never verified")
        model.stop(environment.id)
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.count == 1, "no second stop is sent over an unknown outcome")
        #expect(model.cardStates().first?.availability(of: .stop) != .enabled)
    }

    @Test func tryAgainNeverResendsAForceStop() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.stop(environment.id)
        await waitUntil { model.operations.isEmpty && model.lastErrors[environment.id] != nil && !model.reconciling.contains(environment.id) }
        model.forceStop(environment.id)
        await waitUntil { model.operations.isEmpty && model.lastRequests[environment.id] == .stopEnvironment(environment.id, .force) }
        let before = await backend.receivedRequests.filter { $0 == .stopEnvironment(environment.id, .force) }.count
        #expect(!model.retryAvailable(for: environment.id), "a force-stop is never replayed by Try again")
        model.perform(.retry, for: environment.id)
        try await Task.sleep(for: .milliseconds(100))
        let after = await backend.receivedRequests.filter { $0 == .stopEnvironment(environment.id, .force) }.count
        #expect(after == before, "Try again did not resend the destructive request")
        let retry = model.cardStates().first?.recovery?.options.first { $0.action == .retry }
        #expect(retry?.availability != .enabled)
    }

    @Test func aPendingStopIsLabeledStoppingNotStarting() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(40))
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .hang)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.stop(environment.id)
        await waitUntil { model.operations[environment.id] != nil }
        let card = try #require(model.cardStates().first)
        #expect(card.phase == nil, "no phase has arrived yet")
        #expect(card.statusText == "Stopping the development Mac…")
        model.cancel(environment.id)
    }

    @Test func stopIsWiredToAGracefulStopAndUpdatesTheCard() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .succeed(phases: [ProgressPhase(kind: .stoppingVM)], status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        let before = try #require(model.cardStates().first)
        #expect(before.availability(of: .stop) == .enabled)
        #expect(before.availability(of: .start) == .disabled(reason: "Already running"))
        model.stop(environment.id)
        // The card reads "Checking environment…" until the status re-check that follows the
        // operation has landed.
        await waitUntil { model.statuses[environment.id]?.vm == .stopped && model.operations.isEmpty && model.reconciling.isEmpty }
        let after = try #require(model.cardStates().first)
        #expect(after.statusText == "Stopped")
        #expect(after.availability(of: .stop) == .disabled(reason: "Not running"))
        #expect(after.availability(of: .start) == .enabled)
        let requests = await backend.receivedRequests
        #expect(requests.contains(.stopEnvironment(environment.id, .graceful(deadline: AppModel.gracefulStopDeadline))))
    }

    @Test func forceStopIsOfferedOnlyAfterAGracefulStopTimedOut() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.cardStates().first?.availability(of: .forceStop) != .enabled)
        #expect(!model.canForceStop(environment.id))
        model.stop(environment.id)
        // The force-stop, like every other mutation, waits for the status check that follows
        // the failed graceful stop.
        await waitUntil { model.lastErrors[environment.id] != nil && model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.canForceStop(environment.id))
        #expect(model.cardStates().first?.availability(of: .forceStop) == .enabled)
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        model.forceStop(environment.id)
        await waitUntil { model.statuses[environment.id]?.vm == .stopped && model.operations.isEmpty }
        let requests = await backend.receivedRequests
        #expect(requests.last(where: { if case .stopEnvironment = $0 { true } else { false } }) == .stopEnvironment(environment.id, .force))
        #expect(!model.canForceStop(environment.id))
    }

    @Test func aDisconnectDuringStartShowsCheckingThenTheReconciledStatusWithoutASecondStart() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .disconnect(after: [ProgressPhase(kind: .startingVM)]))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // The runtime finished the start on its own; the reconciled status says so.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        model.start(environment.id)
        await waitUntil { model.lastRequests[environment.id] != nil && model.operations.isEmpty && model.unknownOutcomes.isEmpty }
        // The runtime's own status still named the interrupted start as in flight; it is the
        // reconciliation that settles it, so the runtime is told the VM is idle and read again.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await model.refresh()
        let card = try #require(model.cardStates().first)
        #expect(card.statusText == "Running")
        #expect(card.availability(of: .stop) == .enabled)
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }
        #expect(starts.count == 1, "never replayed")
    }

    @Test func aDisconnectDuringStopLeavesTheOutcomeUnknownUntilInspected() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .disconnect())
        model.stop(environment.id)
        await waitUntil { model.operations.isEmpty && model.unknownOutcomes[environment.id] != nil }
        let card = try #require(model.cardStates().first)
        #expect(card.outcomeUnknown)
        #expect(card.availability(of: .stop) == .disabled(reason: "Checking environment"))
        #expect(card.availability(of: .start) == .disabled(reason: "Checking environment"))
        await backend.script("environmentStatus", .succeed())
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        model.perform(.inspectState, for: environment.id)
        await waitUntil { model.unknownOutcomes.isEmpty }
        #expect(model.cardStates().first?.statusText == "Stopped")
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { true } else { false } }
        #expect(stops.count == 1, "never replayed")
    }
}
