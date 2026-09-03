import AppKit
import Foundation
import GuesthouseCore
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

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
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
        await waitUntil { model.quitFlow == .stopping(environment.id, phase) }
        model.cancelQuit()
        #expect(model.quitCancelRequested)
        #expect(model.quitFlow == .stopping(environment.id, phase), "the step is allowed to end")
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

    @Test func fakeBackendIsChosenFromTheEnvironment() {
        #expect(AppModel.makeBackend(environment: ["GUESTHOUSE_FAKE_RUNTIME": "1"]) is FakeRuntimeBackend)
        #expect(AppModel.makeBackend(environment: ["XCTestConfigurationFilePath": "/x"]) is FakeRuntimeBackend)
        #expect(AppModel.makeBackend(environment: [:]) is RuntimeClient)
    }
}
