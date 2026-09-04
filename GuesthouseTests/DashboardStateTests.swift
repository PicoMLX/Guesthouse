import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor
@Suite struct DashboardStateTests {
    typealias Availability = EnvironmentCardState.Availability

    /// Waits for a condition, and reports when it never became true: a wait that silently
    /// times out leaves the assertions after it testing something else.
    func waitUntil(_ condition: @MainActor () -> Bool, _ description: String = "condition", sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        if !condition() { Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation) }
    }

    func waitUntil(_ condition: @MainActor () async -> Bool, _ description: String = "condition",
                   sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1200 where await !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        if await !condition() { Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation) }
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
        // A sparse capacity is not consumption (MVP-PLAN.md §4): the usage row says nobody
        // has measured it rather than letting the capacity stand in for it.
        #expect(card.details.contains(.init(label: "Disk usage", value: "Not observed yet")))
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
        // The status the operation returned still names the operation until the check that
        // follows it answers; the card reads "Running" only once nothing is in flight on it.
        await waitUntil({
            model.statuses[environment.id]?.vm == .running && model.operations.isEmpty
                && model.statuses[environment.id]?.inFlightOperation == nil
        }, "the check that follows the start")
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
        await waitUntil({ model.operations[first.id]?.acceptedID != nil }, "the operation to be accepted")
        guard case .disabled(let busy) = model.cardStates()[1].availability(of: .start) else { Issue.record("expected Start blocked during the operation"); return }
        #expect(busy.contains("in progress on First"))
        // Only the runtime's own id ends the operation; the provisional one cancels nothing.
        if let accepted = model.operations[first.id]?.acceptedID { for try await _ in backend.send(.cancelOperation(accepted)) {} }
        await waitUntil({ model.operations.isEmpty }, "the canceled operation to end")
    }

    @Test func startIsRefusedEverywhereWhileAnOutcomeIsUnknown() async throws {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        for environment in [first, second] {
            await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        }
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // The start disconnects and the status check that follows fails, so nobody knows
        // whether First's VM came up.
        await backend.script("startEnvironment", .disconnect())
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.start(first.id)
        await waitUntil({ model.unknownOutcomes[first.id] != nil && model.operations.isEmpty }, "the outcome to be unknown")
        let other = try #require(model.cardStates().first { $0.id == second.id })
        guard case .disabled(let reason) = other.availability(of: .start) else { Issue.record("expected Start blocked on the other card"); return }
        #expect(reason.contains("does not know yet"))
        model.start(second.id)
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }
        #expect(starts.count == 1, "no second development Mac is started over an unknown one")
    }

    @Test func theCardSaysItIsCheckingWhileTheStatusAfterAFailureIsRead() async throws {
        // A slow status reply keeps the reconciliation window open long enough to observe it.
        let backend = FakeRuntimeBackend(delay: .milliseconds(150))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil({ model.reconciling.contains(environment.id) }, "the status check after the failure")
        let card = try #require(model.cardStates().first)
        #expect(card.isBusy, "the cached stopped status is not a settled state to act on")
        #expect(card.statusText == "Checking environment…")
        #expect(card.availability(of: .start) == .disabled(reason: "Checking environment"), "Start would be refused, so it is not offered")
        await waitUntil({ model.reconciling.isEmpty }, "the status check to answer")
    }

    @Test func aRetryHonorsTheOneVMGuardLikeStart() async throws {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(first.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(first.id)
        await waitUntil({ model.lastErrors[first.id] != nil && model.operations.isEmpty && model.reconciling.isEmpty }, "the failed start to settle")
        #expect(model.cardStates().first?.recovery?.options.first { $0.action == .retry }?.availability == .enabled)
        // The other development Mac starts running in the meantime.
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .running, readiness: .ready))
        await model.refreshStatus(of: second.id)
        let retry = try #require(model.cardStates().first?.recovery?.options.first { $0.action == .retry })
        guard case .disabled(let reason) = retry.availability else { Issue.record("expected Try again blocked"); return }
        #expect(reason.contains("Second is running"))
        model.perform(.retry, for: first.id)
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }
        #expect(starts.count == 1, "the replayed start the runtime would refuse is never sent")
        #expect(model.lastErrors[first.id] == .guestNotReachable(first.id), "the original error is kept")
    }

    @Test func aSuccessfulOperationLeavesNothingForRetryToReplay() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil({ model.statuses[environment.id]?.vm == .running && model.operations.isEmpty }, "the start to complete")
        #expect(model.lastRequests[environment.id] == nil, "a completed request is not what a later problem retries")
        // A problem the runtime reports on its own afterwards must not replay that start.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .needsAttention(.guestNotReachable(environment.id))))
        await model.refreshStatus(of: environment.id)
        let retry = try #require(model.cardStates().first?.recovery?.options.first { $0.action == .retry })
        guard case .disabled = retry.availability else { Issue.record("expected Try again disabled"); return }
        model.perform(.retry, for: environment.id)
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }
        #expect(starts.count == 1, "the successful start is never re-sent for an unrelated problem")
    }

    @Test func twoRapidRetriesSendOneRequest() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(20))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil({ model.lastErrors[environment.id] != nil && model.operations.isEmpty && model.reconciling.isEmpty }, "the failed start to settle")
        model.perform(.retry, for: environment.id)
        #expect(model.operations[environment.id] != nil, "the reservation is visible before the task runs")
        model.perform(.retry, for: environment.id)
        model.start(environment.id)
        await waitUntil({ model.operations.isEmpty && model.reconciling.isEmpty }, "the replayed start to settle")
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }
        #expect(starts.count == 2, "the first start and one replay, never two concurrent operations")
    }

    @Test func anInspectionThatFindsAnOperationKeepsPolling() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // The full reconciliation found nothing running, so no poll is under way. The user's
        // own check is what discovers the operation.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID()))
        model.perform(.inspectState, for: environment.id)
        await waitUntil({ model.statuses[environment.id]?.inFlightOperation != nil }, "the inspection to find the operation")
        #expect(model.cardStates().first?.isBusy == true)
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        for _ in 0..<600 where model.statuses[environment.id]?.inFlightOperation != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.statuses[environment.id]?.inFlightOperation == nil, "the card does not stay busy for an operation nobody polls")
        #expect(model.cardStates().first?.statusText == "Running")
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
        // Start is offered again only once the check that follows the failure has answered:
        // the status the start began from is dropped, so what the runtime just reported is the
        // only thing Start can be offered from.
        await waitUntil {
            model.lastErrors[environment.id] != nil && model.operations.isEmpty
                && model.statuses[environment.id] != nil && !model.reconciling.contains(environment.id)
        }
        let card = try #require(model.cardStates().first)
        #expect(card.attention == .guestNotReachable(environment.id))
        #expect(card.availability(of: .start) == .enabled, "a stopped, ready VM can be started again after a failed start")
        #expect(!(card.attention?.recoveryActions.isEmpty ?? true))
    }

    @Test func aCardErrorCarriesTheRecoveryTheFailurePrescribes() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        let error = GuesthouseError.runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))
        await backend.script("environmentStatus", .fail(error: error))
        await model.refreshStatus(of: environment.id)
        let card = try #require(model.cardStates().first)
        #expect(card.attention == error)
        #expect(card.availability(of: .start) != .enabled)
        #expect(card.recoveryActions == error.recoveryActions)
        #expect(card.recoveryActions.contains(.inspectState), "the card offers the inspection the error asks for")
        #expect(card.recoveryActions.contains(.openSettings))
    }

    @Test func theRuntimeVersionOnACardComesFromTheService() async throws {
        let backend = FakeRuntimeBackend(versionInfo: RuntimeVersionInfo(serviceVersion: "1.2.3", serviceBuild: "42", tart: .init(version: "2.37.1", verified: true)))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        // A status the real lifecycle builds carries no observation of its own.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        let card = try #require(model.cardStates().first)
        #expect(card.details.contains(.init(label: "Runtime", value: "Tart 2.37.1")))
    }

    @Test func aFullReconciliationClearsAnEarlierQueryFailure() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await model.refreshStatus(of: environment.id)
        #expect(model.cardStates().first?.attention != nil)
        // The menu bar's Check Environment reconciles everything and succeeds this time.
        await backend.script("environmentStatus", .succeed())
        await model.refresh()
        #expect(model.cardStates().first?.attention == nil, "the reconciliation that answered cleared the query failure")
        #expect(model.cardStates().first?.availability(of: .start) == .enabled)
    }

    @Test func startIsBlockedWhileAnotherEnvironmentsStatusIsUnread() async throws {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.cardStates()[1].availability(of: .start) == .enabled)
        // The first environment's inspection fails, so nothing is known about its VM.
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await model.refreshStatus(of: first.id)
        guard case .disabled(let reason) = model.cardStates()[1].availability(of: .start) else {
            Issue.record("expected Start blocked while the other environment is unread"); return
        }
        #expect(reason.contains("First"))
        model.start(second.id)
        #expect(model.operations.isEmpty, "a refused start sends nothing")
    }

    @Test func onlyOnePollerFollowsARecoveredOperation() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID()))
        let model = AppModel(backend: backend) { _ in }
        // Long enough that no poll can fire between the two reconciliations below: what this
        // test counts is how many pollers exist, and a poll that legitimately fires before the
        // second reconciliation replaces it would be counted as a second one.
        model.recoveredOperationPollInterval = .milliseconds(500)
        await model.refresh()
        // Reopening the window, or the menu-bar check, reconciles again while the recovered
        // operation is still in flight.
        await model.refresh()
        // A failed inspection leaves no status, so every poll that is still running makes
        // exactly one query and then ends: the wait below is for all of them to be over.
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await waitUntil { model.statuses[environment.id] == nil && model.recoveredOperationPolls == 0 }
        #expect(model.statuses[environment.id] == nil)
        let queries = await backend.receivedRequests.filter { if case .environmentStatus = $0 { return true }; return false }
        #expect(queries.count == 3, "two reconciliations and one poll, not one poll per reconciliation")
    }

    @Test func aQuitCanceledWhileItInspectsIsNotResurrected() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID()))
        let decisions = AppModelTests.Decision()
        let model = AppModel(backend: backend) { decisions.values.append($0) }
        model.recoveredOperationPollInterval = .seconds(60)
        await model.refresh()
        func statusQueries() async -> Int {
            await backend.receivedRequests.filter { if case .environmentStatus = $0 { return true }; return false }.count
        }
        let beforeQuit = await statusQueries()
        // The quit's own inspection never answers.
        await backend.script("environmentStatus", .hang)
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { await statusQueries() > beforeQuit }
        await backend.script("environmentStatus", .succeed())
        model.cancelQuit()
        #expect(model.quitFlow == .idle)
        // The abandoned attempt has had its turn once no check is reading any more: a second
        // check joins the one in flight rather than adding a listing of its own, so counting
        // listings no longer names that moment.
        await waitUntil({ model.canCheckEnvironment }, "the abandoned attempt to finish")
        #expect(model.quitFlow == .idle, "the abandoned attempt did not reopen the sheet after AppKit was told to stay")
        #expect(decisions.values == [false])
    }

    @Test func aNewerReconciliationSurvivesAnOperationsDisconnect() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(25))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        // The start reports progress for a while and only then loses its connection.
        await backend.script("startEnvironment", .disconnect(after: Array(repeating: ProgressPhase(kind: .startingVM), count: 8)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil { model.operations[environment.id]?.phase != nil }
        // The loss is noticed while nothing else is in flight and reconciliation succeeds,
        // exactly as the client's observer notification makes it.
        await model.refresh()
        #expect(model.launchState == .ready)
        await waitUntil { model.operations.isEmpty }
        #expect(model.launchState == .ready, "the reconciliation that read the actual state was not overwritten by the loss")
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
        await waitUntil { model.lastRequests[environment.id] != nil && model.operations.isEmpty && model.unknownOutcomes.isEmpty }
        #expect(model.launchState == .ready, "the status query answered, so the outcome is settled")
        let requests = await backend.receivedRequests
        #expect(requests.filter { if case .startEnvironment = $0 { true } else { false } }.count == 1, "never replayed")
        #expect(requests.last == .environmentStatus(environment.id), "re-checked after the interruption")
    }

    @Test func aCheckThatFailedIsNotShownAsOneStillRunning() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await model.refreshStatus(of: environment.id)
        let card = try #require(model.cardStates().first)
        #expect(!card.isBusy, "the query ended in a failure; nothing is being checked")
        #expect(card.statusText == "Last check failed")
        #expect(card.attention != nil, "and the failure it ended with is what the card explains")
    }

    @Test func aFailedStartDropsTheStatusItWasStartedFrom() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(50))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.cardStates().first?.availability(of: .start) == .enabled)
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        model.start(environment.id)
        await waitUntil { model.operations.isEmpty }
        // Tart may have launched the VM before the start failed, so the `.stopped` this start
        // began from is not evidence about anything now: it is dropped, and Start stays out
        // until the inspection answers rather than offering an immediate blind retry.
        #expect(model.statuses[environment.id] == nil)
        #expect(model.cardStates().first?.availability(of: .start) == .disabled(reason: "Checking environment"))
        await waitUntil { model.statuses[environment.id] != nil }
        #expect(model.cardStates().first?.availability(of: .start) == .enabled, "and Start returns once the VM answers as stopped and ready")
    }

    @Test func anOperationsFailureSurvivesTheCheckThatFollowsAnEarlierQueryFailure() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .hang)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil { model.operations[environment.id] != nil }
        // A check fails while the start is still running, so the environment carries a
        // query-failure marker when the start reports its own outcome.
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await model.refreshStatus(of: environment.id)
        await backend.script("environmentStatus", .succeed())
        let operation = try #require(model.operations[environment.id]?.id)
        for try await _ in backend.send(.cancelOperation(operation)) {}
        await waitUntil { model.operations.isEmpty && model.statuses[environment.id] != nil }
        #expect(model.lastErrors[environment.id] == .canceled, "the operation's own result is not cleared as if it were the stale query failure")
        let card = try #require(model.cardStates().first)
        #expect(card.attention == .canceled)
        #expect(card.canDismiss, "and the failure the app is holding can be cleared")
        model.dismissError(environment.id)
        #expect(model.lastErrors[environment.id] == nil)
    }

    @Test func aVersionTheServiceCouldNotConfirmIsNotRepeated() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.cardStates().first?.details.contains(.init(label: "Runtime", value: "Tart 2.36.0")) == true)
        // The environments still answer, so the app stays ready; only the supplementary
        // version request is refused, and the row says Unknown rather than repeating a
        // version nothing verified this time (MVP-PLAN.md §2).
        await backend.script("runtimeVersion", .fail(error: .invalidRequest(.tooManyInFlight)))
        await model.refresh()
        #expect(model.launchState == .ready)
        #expect(model.cardStates().first?.details.contains(.init(label: "Runtime", value: "Unknown")) == true)
    }

    @Test func aStartIsRefusedUntilAReconciliationEstablishesTheState() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.cardStates().first?.availability(of: .start) == .enabled)
        // The next check loses its connection. The statuses it never replaced still say the
        // VM is stopped, so nothing in the cached snapshot refuses a Start rendered a moment
        // before the loss.
        await backend.script("listEnvironments", .disconnect())
        await model.refresh()
        guard case .interrupted = model.launchState else { Issue.record("expected interrupted"); return }
        #expect(model.globalStartBlock == nil, "the cached statuses on their own still read as startable")
        model.start(environment.id)
        #expect(model.operations.isEmpty)
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { return true }; return false }
        #expect(starts.isEmpty, "no mutation goes out over state the interrupted check never re-established")
    }

    @Test func anOlderInspectionDoesNotPublishOverANewerReconciliation() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(100))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        func statusQueries() async -> Int {
            await backend.receivedRequests.filter { $0 == .environmentStatus(environment.id) }.count
        }
        let before = await statusQueries()
        // A card inspection that will answer with a failure is outstanding when a newer
        // reconciliation starts reading the actual state.
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        let stale = Task { await model.refreshStatus(of: environment.id) }
        await waitUntil { await statusQueries() > before }
        await backend.script("environmentStatus", .succeed())
        model.startRefresh()
        await stale.value
        // The reconciliation reads three replies where the inspection reads one, so it is
        // still in flight here: what the older reply must not do is delete the status it is
        // reconciling, or leave a failure on the card the newer read disproves.
        #expect(model.statuses[environment.id] != nil, "the superseded reply did not drop the status a newer check is establishing")
        #expect(model.lastErrors[environment.id] == nil)
    }

    @Test func aCheckThatRediscoversAnOperationFollowsItAgain() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID()))
        let model = AppModel(backend: backend) { _ in }
        model.recoveredOperationPollInterval = .milliseconds(20)
        await model.refresh()
        // The poll's own inspection fails, which leaves nothing to follow and ends it.
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await waitUntil { model.statuses[environment.id] == nil && model.recoveredOperationPolls == 0 }
        #expect(model.recoveredOperationPolls == 0, "the poll ended when its query failed")
        // The card's own check succeeds, and the runtime is still running the operation.
        await backend.script("environmentStatus", .succeed())
        await model.refreshStatus(of: environment.id)
        #expect(model.cardStates().first?.isBusy == true)
        // Nothing else follows an operation this app never started, so this check has to pick
        // it up again: the card leaves the busy state when the runtime finishes, rather than
        // blocking every start until someone checks by hand.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await waitUntil { model.statuses[environment.id]?.inFlightOperation == nil }
        #expect(model.statuses[environment.id]?.inFlightOperation == nil)
        #expect(model.cardStates().first?.statusText == "Running")
        #expect(model.cardStates().first?.isBusy == false)
    }

    @Test func aProblemTheStatusKeepsReportingIsNotDismissedAway() {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let error = GuesthouseError.anotherEnvironmentRunning(EnvironmentID())
        #expect(error.recoveryActions == [.cancel], "an error the card can only dismiss needs a control that dismisses it")
        let held = EnvironmentCardState(environment: environment, status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready), operation: nil, lastError: error)
        #expect(held.canDismiss)
        let reported = EnvironmentCardState(environment: environment, status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .needsAttention(error)), operation: nil, lastError: nil)
        #expect(!reported.canDismiss)
    }
}
