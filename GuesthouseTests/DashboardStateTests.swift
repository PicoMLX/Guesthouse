import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor
@Suite struct DashboardStateTests {
    typealias Availability = EnvironmentCardState.Availability

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func freshMacOffersCreationAndNoCards() async {
        let model = await AppModel.preview(PreviewScenarios.freshMac())
        #expect(model.cardStates().isEmpty)
        #expect(model.createAvailability == .enabled)
    }

    @Test func runningEnvironmentCannotStartAgainAndShowsVersions() async throws {
        let model = await AppModel.preview(PreviewScenarios.oneRunningEnvironment())
        let card = try #require(model.cardStates().first)
        #expect(card.statusText == "Running")
        #expect(card.availability(of: .start) == .disabled(reason: "Already running"))
        #expect(card.details.contains(.init(label: "Xcode", value: "17F113")))
        #expect(card.details.contains(.init(label: "Runtime", value: "Tart 2.36.0")))
        #expect(card.details.contains(.init(label: "Codex CLI", value: "Unknown")))
        #expect(model.createAvailability == .enabled)
    }

    @Test func environmentNeedingRepairExplainsWhyStartIsDisabled() async throws {
        let model = await AppModel.preview(PreviewScenarios.environmentNeedingRepair())
        let card = try #require(model.cardStates().first)
        let error = GuesthouseError.hostKeyChanged(card.id)
        #expect(card.attention == error)
        #expect(card.statusText == "Needs attention")
        #expect(card.availability(of: .start) == .disabled(reason: error.userMessage))
        #expect(error.recoveryActions.contains(.repair(.sshPairing)))
    }

    @Test func bothSlotsFullDisablesCreation() async {
        let model = await AppModel.preview(PreviewScenarios.bothSlotsFull())
        #expect(model.cardStates().count == 2)
        guard case .disabled(let reason) = model.createAvailability else { Issue.record("expected the cap to be explained"); return }
        #expect(reason.contains("at most 2"))
    }

    @Test func operationInProgressDisablesStart() async throws {
        let model = await AppModel.preview(PreviewScenarios.operationInProgress())
        let card = try #require(model.cardStates().first)
        #expect(card.isBusy)
        #expect(card.availability(of: .start) == .disabled(reason: "An operation is in progress"))
    }

    @Test func everyActionButStartIsVisiblyUnimplemented() async throws {
        let model = await AppModel.preview(PreviewScenarios.oneRunningEnvironment())
        let card = try #require(model.cardStates().first)
        for action in EnvironmentCardState.Action.allCases where action != .start {
            guard case .notImplemented(let note) = card.availability(of: action), !note.isEmpty else {
                Issue.record("\(action) should be visibly unimplemented"); continue
            }
        }
        #expect(EnvironmentCardState.Action.delete.isDestructive)
        #expect(!EnvironmentCardState.Action.delete.isPrimary)
    }

    @Test func startSendsTheRequestAndUpdatesTheCard() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .succeed(phases: [ProgressPhase(kind: .startingVM)], status: EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(try #require(model.cardStates().first).availability(of: .start) == .enabled)
        model.start(environment.id)
        await waitUntil { model.statuses[environment.id]?.vm == .running && model.operations.isEmpty }
        let card = try #require(model.cardStates().first)
        #expect(card.statusText == "Running")
        #expect(card.attention == nil)
        let requests = await backend.receivedRequests
        #expect(requests.contains(.startEnvironment(environment.id, StartOptions())))
        #expect(requests.filter { if case .startEnvironment = $0 { true } else { false } }.count == 1)
    }

    @Test func startFailureIsShownOnTheCardWithItsRecoveryActions() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil { model.lastErrors[environment.id] != nil && model.operations.isEmpty }
        let card = try #require(model.cardStates().first)
        #expect(card.attention == .guestNotReachable(environment.id))
        #expect(card.availability(of: .start) == .disabled(reason: GuesthouseError.guestNotReachable(environment.id).userMessage))
        #expect(!(card.attention?.recoveryActions.isEmpty ?? true))
    }

    @Test func interruptionDuringStartLeavesTheOutcomeUnknownAndReChecks() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil { model.operations.isEmpty && model.launchState != .ready }
        guard case .interrupted = model.launchState else { Issue.record("expected interrupted"); return }
        let requests = await backend.receivedRequests
        #expect(requests.filter { if case .startEnvironment = $0 { true } else { false } }.count == 1, "never replayed")
        #expect(requests.last == .environmentStatus(environment.id), "re-checked after the interruption")
    }
}
