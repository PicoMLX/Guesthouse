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

    @Test func aFailedStatusQueryIsClearedByALaterSuccess() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await model.refreshStatus(of: environment.id)
        #expect(model.cardStates().first?.attention != nil)
        #expect(model.cardStates().first?.availability(of: .start) != .enabled)
        await backend.script("environmentStatus", .succeed())
        await model.refreshStatus(of: environment.id)
        #expect(model.cardStates().first?.attention == nil, "a successful check clears the query failure")
    }

    @Test func startIsRefusedWhileAnotherVMsOwnershipIsUncertain() async throws {
        let backend = FakeRuntimeBackend()
        let uncertain = DevelopmentEnvironment(name: "One", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let other = DevelopmentEnvironment(name: "Two", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([uncertain, other])
        await backend.setStatus(EnvironmentStatus(environmentID: uncertain.id, vm: .uncertain(reason: "running without a recorded owner"), readiness: .needsAttention(.vmOwnershipUncertain(uncertain.id))))
        await backend.setStatus(EnvironmentStatus(environmentID: other.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        let card = try #require(model.cardStates().first { $0.id == other.id })
        guard case .disabled(let reason) = card.availability(of: .start) else { Issue.record("expected Start disabled"); return }
        #expect(reason.contains("without proof"))
    }

    @Test func aNonRetryableFailureDoesNotOfferStartAgain() {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let status = EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)
        let error = GuesthouseError.runtimeStateUnavailable(reason: SanitizedText("the journal is unwritable"))
        #expect(!error.isRetryable)
        let card = EnvironmentCardState(environment: environment, status: status, operation: nil, lastError: error)
        guard case .disabled = card.availability(of: .start) else { Issue.record("expected Start disabled"); return }
    }

    @Test func aPreservedEnvironmentCannotBeStartedEvenWhenStopped() {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let status = EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .needsAttention(.environmentPreserved(environment.id)))
        let card = EnvironmentCardState(environment: environment, status: status, operation: nil, lastError: nil)
        guard case .disabled = card.availability(of: .start) else { Issue.record("expected Start disabled for a preserved slot"); return }
        let retried = EnvironmentCardState(environment: environment, status: status, operation: nil, lastError: .environmentPreserved(environment.id))
        guard case .disabled = retried.availability(of: .start) else { Issue.record("expected Start disabled after the preserved failure"); return }
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
        #expect(card.details.contains { $0.label == "Disk capacity" })
        #expect(card.details.contains(.init(label: "Accounts", value: "Not observed yet")))
        #expect(card.details.contains(.init(label: "Runtime", value: "Tart 2.36.0")))
        #expect(card.details.contains(.init(label: "Codex CLI", value: "Unknown")))
        #expect(model.createAvailability == .enabled)
    }

    @Test func environmentNeedingRepairExplainsWhyStartIsDisabled() async throws {
        let model = await AppModel.preview(PreviewScenarios.environmentNeedingRepair())
        let card = try #require(model.cardStates().first)
        let error = GuesthouseError.hostKeyChanged(card.id)
        #expect(card.attention == error)
        #expect(card.statusText == "Stopped, needs attention")
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

    @Test func startIsBlockedOnEveryCardWhileAnotherRunsOrOperates() async throws {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .running, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        guard case .disabled(let reason) = model.cardStates()[1].availability(of: .start) else { Issue.record("expected Start blocked"); return }
        #expect(reason.contains("First is running"))
        model.start(second.id)
        #expect(model.operations.isEmpty, "a refused start sends nothing")
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .hang)
        await model.refresh()
        #expect(model.cardStates()[1].availability(of: .start) == .enabled)
        model.start(first.id)
        await waitUntil { model.operations[first.id] != nil }
        guard case .disabled(let busy) = model.cardStates()[1].availability(of: .start) else { Issue.record("expected Start blocked during the operation"); return }
        #expect(busy.contains("in progress on First"))
        if let operation = model.operations[first.id] { for try await _ in backend.send(.cancelOperation(operation.id)) {} }
        await waitUntil { model.operations.isEmpty }
    }

    @Test func recoveredInFlightOperationsArePolledUntilTerminal() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID()))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.cardStates().first?.isBusy == true)
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        for _ in 0..<600 where model.statuses[environment.id]?.inFlightOperation != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.statuses[environment.id]?.inFlightOperation == nil)
        #expect(model.cardStates().first?.statusText == "Running")
    }

    @Test func quitWaitsForAnAcceptedStartBeforeChoosingWhatToStop() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .succeed(phases: [ProgressPhase(kind: .startingVM)], status: EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready)))
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        let decisions = AppModelTests.Decision()
        let model = AppModel(backend: backend) { decisions.values.append($0) }
        await model.refresh()
        model.start(environment.id)
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { model.quitFlow == .terminating }
        let requests = await backend.receivedRequests
        #expect(requests.contains { if case .stopEnvironment(let id, _) = $0 { id == environment.id } else { false } }, "the freshly started VM was stopped before quitting")
        #expect(decisions.values == [true])
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
        #expect(card.availability(of: .start) == .enabled, "a stopped, ready VM can be started again after a failed start")
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
