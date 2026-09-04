import AppKit
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import Guesthouse

@MainActor
@Suite struct AppModelTests {
    final class Decision: @unchecked Sendable {
        var values: [Bool] = []
    }

    func makeModel(_ backend: FakeRuntimeBackend) -> (AppModel, Decision) {
        let decision = Decision()
        let model = AppModel(backend: backend) { decision.values.append($0) }
        return (model, decision)
    }

    func runningEnvironment(_ backend: FakeRuntimeBackend) async -> DevelopmentEnvironment {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        return environment
    }

    /// Waits for a condition, and fails the test if it never holds. A wait that gave up in
    /// silence let every assertion after it run against a model that had not settled, which
    /// reads as a flaky test rather than as the timeout it is. The budget is generous because
    /// the whole suite runs in parallel.
    func waitUntil(_ condition: @MainActor () async -> Bool, _ description: String = "condition",
                   sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1200 where await !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        if await !condition() { Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation) }
    }

    func waitUntil(_ condition: @MainActor () -> Bool, _ description: String = "condition",
                   sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        if !condition() { Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation) }
    }

    @Test func launchStartsByCheckingAndEndsReady() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        let (model, _) = makeModel(backend)
        #expect(model.launchState == .checkingEnvironment)
        await model.refresh()
        #expect(model.launchState == .ready)
        #expect(model.runningEnvironments.count == 1)
    }

    @Test func interruptionDuringRefreshIsSurfacedNotCached() async {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .disconnect())
        let (model, _) = makeModel(backend)
        await model.refresh()
        guard case .interrupted = model.launchState else { Issue.record("expected interrupted, got \(model.launchState)"); return }
    }

    @Test func quitStopsRunningEnvironmentsThenTerminates() async {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .succeed(phases: [ProgressPhase(kind: .stoppingVM)], status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        #expect(model.handleQuitRequest() == false, "the sheet must be shown first")
        #expect(model.quitFlow == .confirming)
        model.confirmStopAndQuit()
        await waitUntil { model.quitFlow == .terminating }
        #expect(decision.values == [true])
        #expect(model.statuses[environment.id]?.vm == .stopped)
        let requests = await backend.receivedRequests
        #expect(requests.contains(.stopEnvironment(environment.id, .graceful(deadline: AppModel.gracefulStopDeadline))))
        #expect(model.handleQuitRequest() == true, "a second request while terminating is allowed through")
    }

    @Test func failedStopOffersForceStopAndForceStopTerminates() async {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { true } else { false } }
        guard case .stopFailed(let error) = model.quitFlow else { Issue.record("expected stopFailed"); return }
        #expect(error == .guestNotReachable(environment.id))
        #expect(decision.values.isEmpty)
        await backend.script("stopEnvironment", .succeed())
        model.forceStopAndQuit()
        await waitUntil { model.quitFlow == .terminating }
        #expect(decision.values == [true])
        let requests = await backend.receivedRequests
        #expect(requests.last == .stopEnvironment(environment.id, .force))
    }

    @Test func cancelReturnsToRunningAndTellsAppKitNotToTerminate() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.cancelQuit()
        #expect(model.quitFlow == .idle)
        #expect(decision.values == [false])
        #expect(model.launchState == .ready)
    }

    @Test func interruptionDuringStopShowsUnknownOutcomeAndReChecks() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .disconnect())
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { true } else { false } }
        guard case .stopFailed(let error) = model.quitFlow, error.caseName == "operationOutcomeUnknown" else { Issue.record("expected unknown outcome, got \(model.quitFlow)"); return }
        guard case .interrupted = model.launchState else { Issue.record("expected interrupted launch state"); return }
        #expect(decision.values.isEmpty)
        await backend.script("stopEnvironment", .succeed())
        await model.refresh()
        #expect(model.launchState == .ready)
    }

    @Test func confirmingLeavesTheConfirmationSynchronouslyAndIgnoresASecondConfirm() async {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        #expect(model.quitFlow == .stopping(nil, nil))
        model.confirmStopAndQuit()
        await waitUntil { model.quitFlow == .terminating }
        #expect(decision.values == [true])
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.count == 1)
    }

    @Test func uncertainOwnershipBlocksQuittingWithoutAForceStop() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .uncertain(reason: "pid reused"), readiness: .needsAttention(.vmOwnershipUncertain(environment.id))))
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(model.quitFlow == .stopFailed(.vmOwnershipUncertain(environment.id)))
        #expect(!model.canForceStop)
        model.forceStopAndQuit()
        #expect(model.quitFlow == .stopFailed(.vmOwnershipUncertain(environment.id)))
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.isEmpty, "neither stop mode is sent for a VM the app may not own")
    }

    @Test func anUnknownOutcomeRequiresACheckBeforeAnyForceStop() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .disconnect())
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(!model.canForceStop)
        model.forceStopAndQuit()
        #expect(decision.values.isEmpty)
        model.inspectAndContinueQuit()
        #expect(model.quitFlow == .checking)
        await waitUntil { model.quitFlow == .confirming }
        #expect(model.launchState == .ready, "the check reconciled with the runtime again")
    }

    @Test func cancelingDuringAStepThatCannotBeInterruptedWaitsForIt() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(40))
        let environment = await runningEnvironment(backend)
        let phase = ProgressPhase(kind: .stoppingVM, cancelable: false)
        let finishing = ProgressPhase(kind: .stoppingVM, fraction: 0.9, cancelable: false)
        await backend.script("stopEnvironment", .succeed(phases: [phase, finishing], status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        // Either protected phase will do: the point is that a cancel during one of them is
        // recorded rather than applied.
        func stoppingPhase() -> ProgressPhase? {
            if case .stopping(_, let reported) = model.quitFlow { return reported }
            return nil
        }
        await waitUntil { stoppingPhase()?.cancelable == false }
        let observed = stoppingPhase()
        model.cancelQuit()
        #expect(model.quitCancelRequested)
        #expect(model.quitFlow == .stopping(environment.id, observed), "the step is allowed to end")
        await waitUntil { model.quitFlow == .idle }
        #expect(decision.values == [false])
        let cancels = await backend.receivedRequests.filter { if case .cancelOperation = $0 { return true }; return false }
        #expect(cancels.isEmpty)
        await waitUntil { model.launchState == .ready }
        #expect(model.statuses[environment.id]?.vm == .stopped, "the stop that ran to its end is reflected after the re-check")
    }

    @Test func aCanceledRefreshKeepsShowingChecking() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(20))
        _ = await runningEnvironment(backend)
        let (model, _) = makeModel(backend)
        let refresh = Task { await model.refresh() }
        refresh.cancel()
        await refresh.value
        #expect(model.launchState == .checkingEnvironment, "a canceled refresh never publishes a Ready")
        await model.refresh()
        #expect(model.launchState == .ready)
    }

    @Test func anIdleConnectionLossDropsTheCachedStateAndReChecks() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(20))
        _ = await runningEnvironment(backend)
        let (model, _) = makeModel(backend)
        await model.refresh()
        #expect(model.launchState == .ready)
        backend.dropConnection()
        await waitUntil { model.launchState != .ready }
        #expect(model.launchState != .ready, "a cached Ready is never kept across a connection loss")
        await waitUntil { model.launchState == .ready }
        let listings = await backend.receivedRequests.filter { $0 == .listEnvironments }
        #expect(listings.count == 2, "the loss triggered one reconciliation")
    }

    @Test func aQuitRequestBeforeTheModelIsBoundIsAnsweredOnBinding() async {
        let backend = FakeRuntimeBackend()
        let (model, _) = makeModel(backend)
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        delegate.model = model
        #expect(model.quitFlow == .confirming)
        model.cancelQuit()
    }

    @Test func onlyTheEnvironmentWhoseGracefulStopFailedIsForced() async {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "One", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Two", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        for environment in [first, second] {
            await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        }
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(first.id)))
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(model.canForceStop)
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready)))
        model.forceStopAndQuit()
        await waitUntil { model.quitFlow == .terminating }
        let stops = await backend.receivedRequests.compactMap { request -> (EnvironmentID, StopMode)? in
            if case .stopEnvironment(let id, let mode) = request { return (id, mode) }
            return nil
        }
        #expect(stops.filter { $0.1 == .force }.map(\.0) == [first.id], "only the failed environment is forced")
        #expect(stops.contains { $0.0 == second.id && $0.1 != .force }, "the other environment is still asked to shut down")
    }

    @Test func anInspectionOnlyFailureNeverOffersAForceStop() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .fail(error: .operationInFlight(OperationID())))
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(!model.canForceStop, "the error asks for inspection, so forcing past it is not offered")
    }

    @Test func twoRapidStartsSendOneRequest() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(20))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let (model, _) = makeModel(backend)
        await model.refresh()
        model.start(environment.id)
        model.start(environment.id)
        #expect(model.operations[environment.id] != nil, "the reservation is visible before the task runs")
        await waitUntil { model.operations[environment.id] == nil }
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { return true }; return false }
        #expect(starts.count == 1)
    }

    @Test func aFailedStatusReplyLeavesNoCachedState() async {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let (model, _) = makeModel(backend)
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await model.refreshStatus(of: environment.id)
        #expect(model.statuses[environment.id] == nil, "a stale status is never kept over a failed query")
        #expect(model.lastErrors[environment.id] == .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable")))
        let card = model.cardStates().first { $0.id == environment.id }
        #expect(card?.availability(of: .start) == .disabled(reason: "Checking environment"))
        #expect(card?.attention == .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable")))
    }

    @Test func quitWaitsForAnOperationOnlyTheStatusReports() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let recovered = OperationID()
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: recovered))
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        let (model, decision) = makeModel(backend)
        // The quit re-inspects on the same cadence as the runtime's status queries; the test
        // shortens it so the wait it is measuring is not several real seconds long.
        model.quitWaitPollInterval = .milliseconds(20)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.quitFlow == .waitingForOperations(environment.id), "a recovered operation keeps the quit waiting")
        #expect(decision.values.isEmpty)
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await waitUntil { model.quitFlow == .terminating }
        #expect(decision.values == [true])
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.count == 1, "the VM the recovered start produced is stopped before quitting")
    }

    @Test func quitRefusesToTerminateWhileAnyOutcomeIsUnknown() async {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "One", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Two", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        for environment in [first, second] {
            await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        }
        let (model, decision) = makeModel(backend)
        await model.refresh()
        // The start disconnects and the check after it fails, so nobody knows whether the VM
        // came up.
        await backend.script("startEnvironment", .disconnect())
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.start(first.id)
        // Including the failed check that follows the start: the outcome is only unsettled
        // once that check has answered, and re-scripting the backend before it lands would let
        // it succeed and settle what this test is about.
        await waitUntil {
            model.unknownOutcomes[first.id] != nil && model.operations.isEmpty
                && model.lastErrors[first.id] != nil && model.statuses[first.id] == nil
        }
        // The runtime then stops listing that environment, so the per-environment checks below
        // can no longer settle it. Its outcome is still open, and a quit must not walk past it.
        await backend.script("environmentStatus", .succeed())
        await backend.setEnvironments([second])
        await model.refresh()
        #expect(model.launchState == .ready)
        #expect(model.unknownOutcomes[first.id] != nil, "no status answered for it, so nothing settled it")
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        guard case .stopFailed(let error) = model.quitFlow, error.caseName == "operationOutcomeUnknown" else {
            Issue.record("expected the quit to stop on the unknown outcome, got \(model.quitFlow)"); return
        }
        #expect(decision.values.isEmpty, "AppKit is never told to terminate over an unknown outcome")
        #expect(!model.canForceStop, "the state is checked, never forced past")
    }

    @Test func anInterruptionWhileTheSheetIsOpenReconcilesBeforeOfferingAgain() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        #expect(model.quitFlow == .confirming)
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        #expect(model.quitFlow == .checking, "the cached state is not offered again unchecked")
        await waitUntil { model.quitFlow == .confirming }
        #expect(model.quitFlow == .confirming, "the check that reconciled the sheet is the one that decides it")
        #expect(model.launchState == .ready)
    }

    @Test func anUnavailableRuntimeStopsAutomaticReconnection() async {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .fail(error: .runtimeMissing))
        let (model, _) = makeModel(backend)
        await model.refresh()
        #expect(model.launchState == .unavailable(.runtimeMissing))
        let before = await backend.receivedRequests.count
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await backend.receivedRequests.count == before, "the app stays on the error instead of reconnecting in a loop")
        model.startRefresh()
        await waitUntil { await backend.receivedRequests.count > before }
        #expect(await backend.receivedRequests.count > before, "an explicit check still reconnects")
    }

    @Test func theInFlightPreviewShowsItsScriptedPhases() async {
        let model = await AppModel.preview(PreviewScenarios.operationInProgress())
        let backend = model.backend as? FakeRuntimeBackend
        var requests: [RuntimeRequest] = []
        for _ in 0..<400 {
            requests = await backend?.receivedRequests ?? []
            if requests.contains(where: { if case .startEnvironment = $0 { return true }; return false }) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests.contains { if case .startEnvironment = $0 { return true }; return false }, "the scripted start is sent despite the seeded in-flight status")
    }

    @Test func anUnavailableRecoverySurvivesTheSessionClosingBehindIt() async {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .fail(error: .protocolMismatch(client: 2, service: 1)))
        let (model, _) = makeModel(backend)
        await model.refresh()
        #expect(model.launchState == .unavailable(.protocolMismatch(client: 2, service: 1)))
        // The service closes the session right after reporting the mismatch.
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        #expect(
            model.launchState == .unavailable(.protocolMismatch(client: 2, service: 1)),
            "the reinstall guidance is kept instead of being replaced by a generic check"
        )
    }

    @Test func aReconciliationThatIsItselfCutOffDoesNotReconnectInALoop() async {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .disconnect())
        let (model, _) = makeModel(backend)
        await model.refresh()
        guard case .interrupted = model.launchState else { Issue.record("expected interrupted, got \(model.launchState)"); return }
        let before = await backend.receivedRequests.count
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await backend.receivedRequests.count == before, "a service that keeps dropping is not relaunched over and over")
    }

    @Test func anExplicitCheckRestoresAutomaticReconciliation() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        await backend.script("listEnvironments", .fail(error: .runtimeMissing))
        let (model, _) = makeModel(backend)
        await model.refresh()
        #expect(model.launchState == .unavailable(.runtimeMissing))
        // The user repairs the runtime and asks for a check, as the menu item does.
        await backend.script("listEnvironments", .succeed())
        await model.refresh()
        #expect(model.launchState == .ready)
        let before = await backend.receivedRequests.count
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        await waitUntil { await backend.receivedRequests.count > before }
        #expect(await backend.receivedRequests.count > before, "a later idle loss reconciles on its own again")
    }

    @Test func aSupersededStopDoesNotCancelTheQuitThatReplacedIt() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(20))
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .succeed(phases: [ProgressPhase(kind: .stoppingVM)], status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopping(_, let phase?) = model.quitFlow { return phase.cancelable }; return false }
        model.cancelQuit()
        #expect(model.quitFlow == .idle)
        // A second Quit begins while the abandoned stop is still unwinding.
        _ = model.handleQuitRequest()
        #expect(model.quitFlow == .confirming)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.quitFlow == .confirming, "the abandoned attempt did not retire the Quit that replaced it")
        #expect(decision.values == [false], "and did not answer AppKit a second time")
    }

    @Test func aFailureFromAnAbandonedQuitDoesNotForceInTheNextAttempt() async {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "One", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Two", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .running, readiness: .ready))
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(second.id)))
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        // The user stays, and the first environment is running by the time they quit again.
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .running, readiness: .ready))
        model.cancelQuit()
        await waitUntil { model.runningEnvironments.count == 2 }
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(model.canForceStop)
        await backend.script("stopEnvironment", .succeed())
        model.forceStopAndQuit()
        await waitUntil { model.quitFlow == .terminating }
        let stops = await backend.receivedRequests.compactMap { request -> (EnvironmentID, StopMode)? in
            if case .stopEnvironment(let id, let mode) = request { return (id, mode) }
            return nil
        }
        #expect(
            !stops.contains { $0.0 == second.id && $0.1 == .force },
            "a target whose graceful stop failed in an abandoned Quit is asked to shut down again first"
        )
        #expect(stops.contains { $0.0 == second.id && $0.1 != .force })
    }

    @Test func aQuitOverAnIncompleteCheckIsNeverForcedPast() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        await backend.script("listEnvironments", .fail(error: .runtimeStarting))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        #expect(model.launchState == .unavailable(.runtimeStarting))
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(model.quitFlow == .stopFailed(.runtimeStarting))
        #expect(!model.canForceStop, "no stop was attempted, so there is nothing to force past")
        model.forceStopAndQuit()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(decision.values.isEmpty, "the app never terminates over a check that did not complete")
        #expect(model.quitFlow == .stopFailed(.runtimeStarting))
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.isEmpty)
    }

    @Test func aSecondCheckJoinsTheOneAlreadyReadingInsteadOfAddingToIt() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(60))
        _ = await runningEnvironment(backend)
        let (model, _) = makeModel(backend)
        model.startRefresh()
        // More checks are asked for while the first one is still reading the list. Cancelling
        // it would not release the request the service is working on, so each would take
        // another slot of the session's cap and the app would end up unavailable on a
        // `tooManyInFlight` for a runtime that is only slow.
        // Waited for by the state it is about rather than by a request count: what makes the
        // menu item unavailable is a check that is reading, and which request goes out first
        // is the reconciliation's business.
        await waitUntil({ !model.canCheckEnvironment }, "the check to start reading")
        #expect(!model.canCheckEnvironment, "a check is already reading; the menu says so rather than appearing to do nothing")
        model.startRefresh()
        model.startRefresh()
        await waitUntil({ model.launchState == .ready && model.canCheckEnvironment }, "the check to finish")
        let listings = await backend.receivedRequests.filter { $0 == .listEnvironments }
        #expect(listings.count == 1, "the later checks joined the one in flight")
        let statusQueries = await backend.receivedRequests.filter { if case .environmentStatus = $0 { return true }; return false }
        #expect(statusQueries.count == 1)
        #expect(model.canCheckEnvironment, "the check finished, so another one may be asked for")
        #expect(model.launchState == .ready)
    }

    @Test func aLossDuringReconciliationLetsThatReconciliationSettle() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(60))
        _ = await runningEnvironment(backend)
        await backend.script("listEnvironments", .disconnect())
        let (model, _) = makeModel(backend)
        model.startRefresh()
        // Any request means the check has started; which one goes out first is the
        // reconciliation's business, and it changes as the stack grows.
        await waitUntil({ await !backend.receivedRequests.isEmpty }, "the check to send its first request")
        // The real client reports the loss to its observers before it throws into the stream
        // the same loss cut off.
        backend.dropConnection()
        await waitUntil { if case .interrupted = model.launchState { return true }; return false }
        // The user asks for a check themselves, which is the only reconnection there should be.
        await model.refresh()
        let listings = await backend.receivedRequests.filter { $0 == .listEnvironments }
        #expect(listings.count == 2, "the interrupted reconciliation reported the loss; no replacement reconnected behind it")
    }

    /// A loss during a reconciliation is left to that reconciliation, which reports it when the
    /// client throws into the streams the loss cut off. One whose queries had all been answered
    /// has no stream left to throw into, so nothing would report the loss and the state it
    /// publishes belongs to a session that is gone.
    @Test func aLossNoStreamCanCarryStillSettlesTheReconciliation() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(300))
        _ = await runningEnvironment(backend)
        let (model, _) = makeModel(backend)
        model.startRefresh()
        // Any request means the reconciliation is reading; which one goes out first is its own
        // business, and a bare count no longer names that moment.
        await waitUntil({ await !backend.receivedRequests.isEmpty }, "the reconciliation to start reading")
        #expect(model.launchState == .checkingEnvironment, "the reconciliation is still reading")
        // The session closes, and every query this reconciliation asked for is still answered:
        // the streams complete normally, so none of them carries the loss.
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        await waitUntil { model.launchState != .checkingEnvironment }
        guard case .interrupted = model.launchState else {
            Issue.record("expected interrupted, got \(model.launchState)")
            return
        }
        let before = await backend.receivedRequests.count
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await backend.receivedRequests.count == before, "the loss carries its own recovery; nothing reconnects behind it")
    }

    @Test func quitReReadsTheStateBeforeChoosingWhatToStop() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        #expect(model.runningEnvironments.isEmpty)
        // Tart starts the VM outside Guesthouse: nothing the app can observe changes, and the
        // XPC connection stays up, so the cached Ready still says nothing is running.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { model.quitFlow == .terminating }
        #expect(decision.values == [true])
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops == [.stopEnvironment(environment.id, .graceful(deadline: AppModel.gracefulStopDeadline))], "the quit-time check found the VM and stopped it")
    }

    @Test func aLossBeforeTheStopStreamOpensIsReconciledFirst() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        #expect(model.quitFlow == .stopping(nil, nil))
        // The service goes away before the queued stop has opened a stream to report it, and
        // the restarted service finds the VM running after all.
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        await waitUntil { model.quitFlow == .terminating }
        #expect(decision.values == [true])
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.count == 1, "Guesthouse never approved termination over a VM it had not read back")
    }

    @Test func aQuitCanceledBeforeItsCheckRunsIsNotResurrected() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let recovered = OperationID()
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: recovered))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        // Cancel lands before the queued task has run at all.
        model.cancelQuit()
        #expect(model.quitFlow == .idle)
        #expect(decision.values == [false])
        // The cancellation's own re-check is the next reconciliation; once it has happened,
        // the abandoned attempt has had its turn too.
        await waitUntil { await backend.receivedRequests.filter { $0 == .listEnvironments }.count == 2 }
        #expect(model.quitFlow == .idle, "the abandoned attempt did not reopen the sheet after AppKit was told to stay")
        #expect(decision.values == [false])
    }

    @Test func theMenuNamesOwnershipItCannotProveInsteadOfClaimingNothingRuns() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .uncertain(reason: "pid reused"), readiness: .needsAttention(.vmOwnershipUncertain(environment.id))))
        let (model, _) = makeModel(backend)
        await model.refresh()
        #expect(model.launchState == .ready)
        #expect(model.runningEnvironments.isEmpty)
        #expect(model.runningSummary == "1 development Mac Guesthouse cannot identify")
    }

    /// A card-level status query that failed leaves nothing known about that VM. The menu bar
    /// and the sentence the Quit decision is made on must not report it as stopped: that is the
    /// same unproven claim uncertainty is kept out of.
    @Test func anEnvironmentThatDidNotAnswerIsNeverReportedAsNotRunning() async {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let (model, _) = makeModel(backend)
        await model.refresh()
        #expect(model.runningSummary == "1 running")
        await backend.script("environmentStatus", .fail(error: .runtimeMissing))
        await model.refreshStatus(of: environment.id)
        #expect(model.statuses[environment.id] == nil, "the query failed, so nothing is known about this VM")
        #expect(model.runningSummary == "1 development Mac Guesthouse could not check")
        #expect(model.quitConfirmationMessage.contains("cannot tell whether it is running"))
        #expect(!model.quitConfirmationMessage.contains("No development Mac is running"))
    }

    /// The runtime's status refresh after a start is a bounded courtesy that can time out, so a
    /// completed start can arrive without describing the environment. What was cached before it
    /// describes a VM that is now running, and releasing the reservation over that would offer
    /// Start again for as long as the app's own inspection takes.
    @Test func aStartThatCompletedWithoutAStatusLeavesNothingActionableBehind() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(200))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let (model, _) = makeModel(backend)
        await model.refresh()
        // Accepted and completed, with no status of its own in between.
        await backend.script("startEnvironment", .succeed())
        model.start(environment.id)
        await waitUntil { model.operations[environment.id] == nil }
        #expect(model.statuses[environment.id] == nil, "what was cached before the start says nothing about the state after it")
        #expect(model.globalStartBlock != nil, "nothing is started while this environment has not answered")
    }

    @Test func aStopRefusedBeforeAcceptanceIsNeverForcedPast() async {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        // The service refuses the stop while its lifecycle is still initializing: no graceful
        // shutdown was ever asked for.
        await backend.script("stopEnvironment", .refuse(error: .runtimeStarting))
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(model.quitFlow == .stopFailed(.runtimeStarting))
        #expect(!model.canForceStop, "a stop the runtime never accepted did not fail gracefully")
        model.forceStopAndQuit()
        let stops = await backend.receivedRequests.compactMap { request -> StopMode? in
            if case .stopEnvironment(let id, let mode) = request, id == environment.id { return mode }
            return nil
        }
        #expect(!stops.contains(.force), "the VM is never hard-stopped without having been asked to shut down")
    }

    @Test func aFailureThatPrescribesARepairIsNotAnsweredWithACheck() async {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .fail(error: .runtimeMissing))
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(model.quitFlow == .stopFailed(.runtimeMissing))
        #expect(model.quitRecovery == .guidance(GuesthouseError.runtimeMissing.recoverySuggestion ?? ""))
        let before = await backend.receivedRequests.count
        model.inspectAndContinueQuit()
        #expect(model.quitFlow == .stopFailed(.runtimeMissing), "a check that only returns the same failure is not offered")
        #expect(await backend.receivedRequests.count == before)
    }

    @Test func aTerminalQuitFailureSurvivesTheSessionClosingBehindIt() async {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .fail(error: .protocolMismatch(client: 2, service: 1)))
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(model.quitFlow == .stopFailed(.protocolMismatch(client: 2, service: 1)))
        // The service closes the incompatible session right after reporting the mismatch.
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        #expect(
            model.quitFlow == .stopFailed(.protocolMismatch(client: 2, service: 1)),
            "the sheet keeps the reinstall recovery instead of relaunching the service to reach it again"
        )
    }

    @Test func aLostQuitTimeCheckKeepsItsReadOnlyRecovery() async {
        let backend = FakeRuntimeBackend()
        _ = await runningEnvironment(backend)
        await backend.script("listEnvironments", .disconnect())
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .checkFailed = model.quitFlow { return true }; return false }
        guard case .checkFailed(let interruption) = model.quitFlow else { Issue.record("expected checkFailed, got \(model.quitFlow)"); return }
        #expect(interruption.operationID == nil, "the check mutated nothing, so it names no operation")
        #expect(interruption.recoveryActions == [.retry])
        #expect(model.quitRecovery == .check)
        #expect(decision.values.isEmpty)
    }

    @Test func aRuntimeReportedUnknownOutcomeStopsTheQuit() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        // The VM is stopped and this app holds no marker of its own — a successful refresh
        // clears one — but the runtime says it cannot account for the last mutation.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .needsAttention(.operationOutcomeUnknown(OperationID()))))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        #expect(model.unknownOutcomes.isEmpty, "nothing this app is tracking; only the runtime's own verdict")
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        guard case .stopFailed(let error) = model.quitFlow, error.caseName == "operationOutcomeUnknown" else {
            Issue.record("expected the quit to stop on the runtime's unresolved outcome, got \(model.quitFlow)"); return
        }
        #expect(decision.values.isEmpty, "AppKit is never told to terminate over a mutation the runtime cannot account for")
        #expect(!model.canForceStop, "the state is checked, never forced past")
    }

    @Test func anUnlistedReconciliationBlocksEveryStart() async {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Other Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // The first environment's start fails and the inspection that would establish its VM
        // state fails too, so it stays under reconciliation.
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(first.id)))
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.start(first.id)
        // The inspection that follows the start fails, which is what drops the status and
        // leaves the entry standing. The operation's own tail drops the status too, so the
        // wait names the failure that inspection records: re-scripting the backend before it
        // lands would let it succeed and settle exactly what this test is about.
        await waitUntil {
            model.operations.isEmpty && model.statuses[first.id] == nil
                && model.lastErrors[first.id] != nil && model.reconciling.contains(first.id)
        }
        // The runtime then stops listing it, which deliberately keeps the entry: its VM state
        // was never established, and the runtime runs one development Mac at a time.
        // Unlisted first, and only then answering again: while it is still listed a check that
        // succeeds settles it legitimately, which is not what this test is about.
        await backend.setEnvironments([second])
        await backend.script("environmentStatus", .succeed())
        await model.refresh()
        #expect(model.reconciling.contains(first.id), "no status answered for it, so nothing settled it")
        let card = model.cardStates().first { $0.id == second.id }
        #expect(card?.availability(of: .start) != .enabled, "the listed environment is not started over an unaccounted-for one")
    }

    @Test func aQuitStopsWhileAnEnvironmentsStateWasNeverReadBack() async {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Other Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        let (model, decision) = makeModel(backend)
        await model.refresh()
        // An ordinary failure, so there is no unknown-outcome marker: what stands is the
        // reconciliation entry the failed inspection after it left behind.
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(first.id)))
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.start(first.id)
        await waitUntil {
            model.operations.isEmpty && model.statuses[first.id] == nil
                && model.lastErrors[first.id] != nil && model.reconciling.contains(first.id)
        }
        // The runtime then stops listing it, so the quit's own loop never inspects it: the VM
        // that start may have launched is not accounted for by anything.
        await backend.setEnvironments([second])
        await backend.script("environmentStatus", .succeed())
        await model.refresh()
        #expect(model.reconciling.contains(first.id), "nothing answered for it, so nothing settled it")
        #expect(model.unknownOutcomes.isEmpty, "and it is not an unknown outcome: the operation reported an ordinary failure")
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil({ if case .stopFailed = model.quitFlow { return true }; return false }, "the quit to stop on the unread state")
        #expect(decision.values.isEmpty, "AppKit is never told to terminate over a development Mac nobody could read")
    }

    @Test func aFullRefreshDoesNotPublishAReadANewerInspectionHasOvertaken() async {
        let fake = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await fake.setEnvironments([environment])
        await fake.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let older = EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID())
        let newer = EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready)
        let answers = Mutex<[[RuntimeEvent]]>([])
        let backend = HeldReplyBackend(fake) { request in
            guard case .environmentStatus = request else { return nil }
            return answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // A snapshot is assembled over several round trips — the listing, one status per
        // environment, then the version — so an inspection can read this environment after the
        // snapshot did and still answer before the snapshot is published.
        answers.withLock { $0 = [[.status(older)], [.status(newer)]] }
        let snapshot = Task { await model.refresh() }
        await waitUntil({ backend.heldReplies == 1 }, "the reconciliation's own read of this environment")
        let inspection = Task { await model.refreshStatus(of: environment.id) }
        await waitUntil({ backend.heldReplies == 2 }, "the card's check, which reads it later")
        // The card's check answers first; the reconciliation publishes afterwards.
        backend.release(1)
        await inspection.value
        backend.release(0)
        await snapshot.value
        #expect(model.statuses[environment.id]?.vm == .running, "the newer reading of this environment stands")
        #expect(model.statuses[environment.id]?.inFlightOperation == nil, "a settled operation is not put back in flight")
    }

    @Test func aFullRefreshRetiresTheInspectionItSupersedes() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // A check whose stream never answers. A refresh that only bumps the generation leaves
        // its request outstanding for the life of the session, and the recovered-operation
        // poll skips an environment whose inspection is already running — so an operation only
        // the runtime reports would never be seen to end.
        await backend.script("environmentStatus", .hang)
        let ended = Box<Bool>()
        let hung = Task { await model.refreshStatus(of: environment.id); ended.value = true }
        await waitUntil({ await backend.receivedRequests.contains(.environmentStatus(environment.id)) }, "the hung check to be sent")
        await backend.script("environmentStatus", .succeed())
        await model.refresh()
        await waitUntil({ ended.value == true }, "the superseded check to be retired by the reconciliation")
        await hung.value
        #expect(model.statuses[environment.id] != nil, "and the reconciliation's own answer is what stands")
        #expect(model.launchState == .ready, "a retired inspection reports no interruption over it")
    }

    @Test func aLossReconciledBeforeItLandsDoesNotReopenTheOutcome() async {
        let fake = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await fake.setEnvironments([environment])
        await fake.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let backend = HeldLossBackend(fake) { if case .startEnvironment = $0 { true } else { false } }
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil({ backend.heldLosses == 1 }, "the start to reach the runtime")
        // The connection-loss observer's own reconciliation gets there first and reads back
        // exactly the state this interrupted start would otherwise call unknown.
        await fake.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await model.refresh()
        backend.releaseLoss()
        await waitUntil({ model.operations[environment.id] == nil }, "the interrupted stream to finish")
        #expect(model.unknownOutcomes[environment.id] == nil, "the actual state has been inspected, which is what an unknown outcome waits for")
        #expect(model.statuses[environment.id]?.vm == .running, "the reconciled status is not dropped again")
        #expect(!model.reconciling.contains(environment.id), "and no second check is asked for over the one that answered")
        // The block that remains is the ordinary one-VM-at-a-time rule over a running machine,
        // not an unaccounted-for mutation: nothing is waiting on a check that already happened.
        #expect(model.globalStartBlock?.contains("checking") != true)
    }

    @Test func aCancellationLostAfterAReconciliationDoesNotTakeTheDashboardAway() async throws {
        let fake = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await fake.setEnvironments([environment])
        await fake.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready, inFlightOperation: OperationID()))
        let backend = HeldLossBackend(fake) { if case .cancelOperation = $0 { true } else { false } }
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.cancel(environment.id)
        await waitUntil({ backend.heldLosses == 1 }, "the cancellation to reach the runtime")
        await model.refresh()
        #expect(model.launchState == .ready, "the reconciliation re-established the app's state")
        backend.releaseLoss()
        // The loss belongs to a session a newer reconciliation has already replaced. This path
        // starts no check of its own, so putting the app back on the interrupted screen would
        // leave the whole dashboard unavailable until the user asked by hand.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.launchState == .ready)
    }

    @Test func aFullRefreshCannotBeOverwrittenByAnOlderInspection() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(60))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // A card inspection is outstanding when a newer full reconciliation publishes. The
        // full refresh reads every status too, so it takes part in the same ordering: the
        // older inspection's answer is discarded rather than replacing the newer snapshot.
        let inspection = Task { await model.refreshStatus(of: environment.id) }
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await model.refresh()
        #expect(model.statuses[environment.id]?.vm == .running)
        await inspection.value
        #expect(model.statuses[environment.id]?.vm == .running, "the newer reconciliation stands")
    }

    @Test func aSupersededStatusRequestIsCancelledRatherThanLeftOutstanding() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // The first check's stream never answers. A generation check alone would discard its
        // reply but leave the request holding one of the session's in-flight slots forever.
        await backend.script("environmentStatus", .hang)
        let hung = Task { await model.refreshStatus(of: environment.id) }
        await waitUntil { await backend.receivedRequests.contains(.environmentStatus(environment.id)) }
        await backend.script("environmentStatus", .succeed())
        await model.refreshStatus(of: environment.id)
        // The replacement ends the request it superseded, so the hung inspection returns.
        await hung.value
        #expect(model.statuses[environment.id] != nil, "and the newer answer is what stands")
        #expect(model.launchState == .ready, "a cancelled inspection reports no interruption over it")
    }

    @Test func fakeBackendIsChosenFromTheEnvironment() {
        // The test host always gets the fake, in any configuration.
        #expect(AppModel.makeBackend(environment: ["XCTestConfigurationFilePath": "/x"]) is FakeRuntimeBackend)
        #expect(AppModel.makeBackend(environment: [:]) is RuntimeClient)
        // The variable is a development convenience. A shipped app must not let it swap the
        // runtime for an empty in-memory one, or Quit would find nothing to stop.
        #if DEBUG
        #expect(AppModel.makeBackend(environment: ["GUESTHOUSE_FAKE_RUNTIME": "1"]) is FakeRuntimeBackend)
        #else
        #expect(AppModel.makeBackend(environment: ["GUESTHOUSE_FAKE_RUNTIME": "1"]) is RuntimeClient)
        #endif
    }

    @Test func aMenuCheckCannotInvalidateTheQuitFlowsOwnCheck() async {
        let backend = FakeRuntimeBackend(delay: .milliseconds(60))
        _ = await runningEnvironment(backend)
        let (model, decision) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .checking = model.quitFlow { return true }; return false }
        #expect(!model.canCheckEnvironment, "the menu says the check is unavailable while Quit owns one")
        // A menu check here would retire the Quit's reconciliation, leaving it to read
        // "checking" as a check that failed.
        model.startRefresh()
        await waitUntil { if case .stopping = model.quitFlow { return true }; return false }
        await waitUntil { model.quitFlow == .terminating }
        #expect(decision.values == [true], "the Quit reached its own decision")
    }

    @Test func aForceStopReReadsWhatIsRunningBeforeItSignalsAnything() async {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        let (model, _) = makeModel(backend)
        await model.refresh()
        _ = model.handleQuitRequest()
        model.confirmStopAndQuit()
        await waitUntil { if case .stopFailed = model.quitFlow { return true }; return false }
        #expect(model.canForceStop)
        // While the warning is on screen the development Mac finishes shutting down. The force
        // stop must act on that, not on the snapshot the sheet was built from.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let stopsBefore = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }.count
        model.forceStopAndQuit()
        await waitUntil { model.quitFlow == .terminating }
        let stopsAfter = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }.count
        #expect(stopsAfter == stopsBefore, "nothing is signaled for a development Mac that is no longer running")
    }

    @Test func aFullReconciliationSettlesTheOutcomeItsStatusesAnswer() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let (model, _) = makeModel(backend)
        await model.refresh()
        // The runtime cannot account for the mutation, and the check that follows is lost, so
        // nothing settles the failure that reported it.
        let unresolved = OperationID()
        await backend.script("startEnvironment", .fail(error: .operationOutcomeUnknown(unresolved)))
        await backend.script("environmentStatus", .disconnect())
        model.start(environment.id)
        await waitUntil { model.operations.isEmpty && model.unknownOutcomes[environment.id] != nil }
        #expect(model.lastErrors[environment.id] == .operationOutcomeUnknown(unresolved))
        // A full reconciliation reads the environment's actual state, so it settles that
        // outcome exactly as a single-card check would.
        await backend.script("environmentStatus", .succeed())
        await model.refresh()
        #expect(model.launchState == .ready)
        #expect(model.lastErrors[environment.id] == nil, "the reconciliation that answered settled the outcome it could not account for")
        let card = try #require(model.cardStates().first)
        #expect(!card.outcomeUnknown)
        #expect(card.availability(of: .start) == .enabled)
    }

    @Test func aRefusedCancellationSurvivesTheCheckAfterAnEarlierQueryFailure() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .hang)
        let (model, _) = makeModel(backend)
        await model.refresh()
        model.start(environment.id)
        await waitUntil { model.operations[environment.id]?.acceptedID != nil }
        let accepted = try #require(model.operations[environment.id]?.acceptedID)
        // A check fails while the start is still running, so a query-failure marker is left
        // standing when the cancellation is refused.
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await model.refreshStatus(of: environment.id)
        await backend.script("cancelOperation", .fail(error: .operationInFlight(accepted)))
        model.cancel(environment.id)
        await waitUntil { model.lastErrors[environment.id] == .operationInFlight(accepted) }
        // The operation is still in flight, so the refusal is still the news. A check that
        // succeeds must not clear it as if it were the stale query failure.
        await backend.script("environmentStatus", .succeed())
        await model.refreshStatus(of: environment.id)
        #expect(model.statuses[environment.id]?.inFlightOperation == accepted)
        #expect(model.lastErrors[environment.id] == .operationInFlight(accepted), "the refusal is what the card still explains")
        #expect(model.cardStates().first?.attention == .operationInFlight(accepted))
        await backend.script("cancelOperation", .succeed())
        model.cancel(environment.id)
        await waitUntil { model.operations.isEmpty }
    }

    @Test func theRecoveredOperationPollWaitsForAnInspectionAlreadyRunning() async throws {
        // Every query takes longer than either loop's interval, which is the case in which two
        // loops that replace each other's request cancel it before it can ever answer.
        let backend = FakeRuntimeBackend(delay: .milliseconds(100))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID()))
        let (model, _) = makeModel(backend)
        model.recoveredOperationPollInterval = .milliseconds(30)
        await model.refresh()
        // A second caller inspects the same environment on the same interval while the poll
        // follows the recovered operation; a quit's own wait loop is that caller in the app.
        let other = Task {
            for _ in 0..<60 {
                await model.refreshStatus(of: environment.id)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        // The operation finishes on the runtime. Only an inspection that is allowed to answer
        // can tell the app, so the card leaves the busy state only if the two loops are not
        // cancelling each other's request every interval.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await waitUntil { model.statuses[environment.id]?.inFlightOperation == nil }
        #expect(model.statuses[environment.id]?.inFlightOperation == nil, "an inspection answered instead of being replaced before it could")
        other.cancel()
        await other.value
    }

    @Test func oneEnvironmentAnsweringDoesNotEndTheInterruptionOnItsOwn() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let (model, _) = makeModel(backend)
        await model.refresh()
        // The start loses its stream, and the reconciliation its answer asks for cannot read
        // the listing: only this one environment has answered since the session dropped.
        await backend.script("startEnvironment", .disconnect())
        await backend.script("listEnvironments", .disconnect())
        model.start(environment.id)
        await waitUntil { model.operations.isEmpty && model.statuses[environment.id] != nil }
        // Long enough for that reconciliation to fail.
        try? await Task.sleep(for: .milliseconds(200))
        guard case .interrupted = model.launchState else {
            Issue.record("expected the app to stay interrupted until a full check succeeds, got \(model.launchState)")
            return
        }
        // Once the listing answers again, the reconciliation is what restores Ready.
        await backend.script("listEnvironments", .succeed())
        await model.refreshStatus(of: environment.id)
        await waitUntil { model.launchState == .ready }
        #expect(model.launchState == .ready, "the full check re-read the listing and every environment")
    }

    @Test func theQuitConfirmationNamesOwnershipItCannotEstablish() async {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(
            environmentID: environment.id,
            vm: .uncertain(reason: "running without a recorded owner"),
            readiness: .needsAttention(.vmOwnershipUncertain(environment.id))
        ))
        let (model, _) = makeModel(backend)
        await model.refresh()
        #expect(model.runningEnvironments.isEmpty)
        #expect(model.quitConfirmationMessage.contains("cannot tell"), "an unproven state is never reported as nothing running")
        #expect(!model.quitConfirmationMessage.contains("No development Mac is running"))
    }
}
