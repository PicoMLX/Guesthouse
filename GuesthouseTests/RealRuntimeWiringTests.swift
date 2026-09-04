import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor
@Suite struct RealRuntimeWiringTests {
    /// Waits for a condition, and reports when it never became true: a wait that returns
    /// silently after its last attempt leaves every assertion behind it testing a state the
    /// test never actually reached, which is how these tests could pass without observing the
    /// behaviour they name.
    func waitUntil(_ condition: @MainActor () -> Bool, _ description: String = "condition", sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        if !condition() { Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation) }
    }

    func waitUntil(_ condition: @MainActor () async -> Bool, _ description: String = "condition", sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<600 where await !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        if await !condition() { Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation) }
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
        // The reservation the first activation made refuses the second, as it does for Stop.
        model.forceStop(environment.id)
        await waitUntil { model.statuses[environment.id]?.vm == .stopped && model.operations.isEmpty }
        let requests = await backend.receivedRequests
        #expect(requests.last(where: { if case .stopEnvironment = $0 { true } else { false } }) == .stopEnvironment(environment.id, .force))
        #expect(requests.filter { $0 == .stopEnvironment(environment.id, .force) }.count == 1, "only one force-stop was sent")
        #expect(!model.canForceStop(environment.id))
    }

    @Test func aForceStopThatFailedIsOfferedAgainRatherThanStartingOver() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.stop(environment.id)
        await waitUntil { model.lastErrors[environment.id] != nil && model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.canForceStop(environment.id))
        // The force-stop itself fails with a retryable error — a Tart invocation that timed
        // out is reported as `guestNotReachable` — and the check still finds the VM running.
        await backend.script("stopEnvironment", .fail(error: .guestNotReachable(environment.id)))
        model.forceStop(environment.id)
        await waitUntil { model.lastRequests[environment.id] == .stopEnvironment(environment.id, .force) && model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.statuses[environment.id]?.vm == .running, "the development Mac the force-stop was for is still running")
        #expect(!model.retryAvailable(for: environment.id), "the destructive request is still never replayed by Try again")
        // So the warned force-stop is the way out, not another 60-second graceful attempt.
        #expect(model.canForceStop(environment.id))
        #expect(model.cardStates().first?.availability(of: .forceStop) == .enabled)
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        model.forceStop(environment.id)
        await waitUntil { model.statuses[environment.id]?.vm == .stopped && model.operations.isEmpty }
        let forced = await backend.receivedRequests.filter { $0 == .stopEnvironment(environment.id, .force) }
        #expect(forced.count == 2, "the second escalation was sent, each behind its own warning")
        let gracefulStops = await backend.receivedRequests.filter { if case .stopEnvironment(_, .graceful) = $0 { true } else { false } }
        #expect(gracefulStops.count == 1, "and no second graceful stop was needed to unlock it")
    }

    @Test func stopControlsWaitForTheCheckThatFollowsAFailedStop() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(200))
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.stop(environment.id)
        await waitUntil { model.reconciling.contains(environment.id) }
        #expect(model.reconciling.contains(environment.id), "the status query that follows the stop is still outstanding")
        #expect(!model.canMutate(environment.id))
        let card = try #require(model.cardStates().first)
        #expect(card.availability(of: .stop) == .disabled(reason: "Checking environment"), "a control the model refuses is not rendered as enabled")
        #expect(card.availability(of: .forceStop) != .enabled)
        await waitUntil { !model.reconciling.contains(environment.id) }
        #expect(model.cardStates().first?.availability(of: .forceStop) == .enabled, "and is offered once the state has been inspected")
    }

    @Test func tryAgainIsNotOfferedForAStopTheVMAlreadyCompleted() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // The guest finishes shutting down while the timeout is being reported.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        model.stop(environment.id)
        await waitUntil { model.statuses[environment.id]?.vm == .stopped && model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.lastErrors[environment.id] == .gracefulStopTimedOut(environment.id))
        #expect(!model.retryAvailable(for: environment.id), "the reconciled status says the VM is already stopped")
        #expect(!model.canForceStop(environment.id))
        let before = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }.count
        model.perform(.retry, for: environment.id)
        try await Task.sleep(for: .milliseconds(100))
        let after = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }.count
        #expect(after == before, "no second stop is sent to a VM that has stopped")
    }

    @Test func twoRapidStopsSendOnlyOne() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(20))
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.stop(environment.id)
        model.stop(environment.id)
        #expect(model.operations[environment.id] != nil, "the operation is reserved before the task runs")
        await waitUntil { model.statuses[environment.id]?.vm == .stopped && model.operations.isEmpty }
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.count == 1, "the second activation found the operation already reserved")
    }

    @Test func forceStopIsOfferedAfterAnyVerifiedGracefulStopFailure() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        // `EnvironmentLifecycle` reports a Tart stop that did not work this way, not only as a
        // timeout; the VM is still running either way.
        await backend.script("stopEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.stop(environment.id)
        await waitUntil { model.lastErrors[environment.id] != nil && model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.statuses[environment.id]?.vm == .running, "the check verified the VM is still running")
        #expect(model.canForceStop(environment.id))
        #expect(model.cardStates().first?.availability(of: .forceStop) == .enabled)
    }

    @Test func aStopOffersNoCancelControl() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(20))
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .hang)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.stop(environment.id)
        await waitUntil { model.operations[environment.id]?.acceptedID != nil }
        let card = try #require(model.cardStates().first)
        guard case .unavailable(let reason)? = card.progress?.cancelability else {
            Issue.record("expected cancellation to be unavailable, got \(String(describing: card.progress?.cancelability))")
            return
        }
        #expect(reason.contains("runs to its end"))
        model.cancel(environment.id)
        await waitUntil { model.operations.isEmpty }
    }

    @Test func aRuntimeReportedUnknownOutcomeBlocksStopUntilItIsResolved() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .needsAttention(.operationOutcomeUnknown(OperationID()))))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.unknownOutcomes.isEmpty, "nothing this window started was interrupted")
        #expect(!model.canMutate(environment.id), "the runtime says an operation's outcome is unresolved")
        #expect(model.cardStates().first?.availability(of: .stop) == .disabled(reason: "Checking environment"))
        model.stop(environment.id)
        try await Task.sleep(for: .milliseconds(100))
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.isEmpty, "no blind mutation is sent before the interrupted operation is resolved")
    }

    @Test func aStopIsRefusedWhileAnotherEnvironmentHasAnOperation() async throws {
        let backend = FakeRuntimeBackend()
        let busy = DevelopmentEnvironment(name: "One", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let running = DevelopmentEnvironment(name: "Two", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([busy, running])
        await backend.setStatus(EnvironmentStatus(environmentID: busy.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID()))
        await backend.setStatus(EnvironmentStatus(environmentID: running.id, vm: .running, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(!model.canMutate(running.id), "the runtime runs one lifecycle operation at a time")
        guard case .disabled(let reason)? = model.cardStates().last?.availability(of: .stop) else {
            Issue.record("expected Stop disabled while another environment is busy")
            return
        }
        #expect(reason.contains("in progress on One"))
        model.stop(running.id)
        try await Task.sleep(for: .milliseconds(100))
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { return true }; return false }
        #expect(stops.isEmpty, "the runtime would refuse it and replace the card with an operationInFlight error")
        // Let the recovered-operation poll finish so it does not outlive the test.
        await backend.setStatus(EnvironmentStatus(environmentID: busy.id, vm: .stopped, readiness: .ready))
        await waitUntil { model.statuses[busy.id]?.inFlightOperation == nil }
    }

    @Test func everyRuntimeLogLineGoesThroughTheRedactor() async {
        let model = AppModel(backend: FakeRuntimeBackend()) { _ in }
        let line = model.redactedLogLine("runtime connection interrupted; Authorization: token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab")
        #expect(!line.text.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(line.text.contains("runtime connection interrupted"))
    }

    @Test func aStopLostToADisconnectIsNoLongerWhatTryAgainReplays() async throws {
        // The stream is lost rather than ending in a terminal `.operationOutcomeUnknown`, so
        // the catch writes the marker and no error: keying the cleanup off the error the card
        // shows missed this path entirely and left the stop sitting in `lastRequests`.
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        await backend.script("stopEnvironment", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.stop(environment.id)
        await waitUntil({ model.operations.isEmpty && model.unknownOutcomes.isEmpty && !model.reconciling.contains(environment.id) },
                        "the check after the loss to settle the outcome")
        #expect(model.lastRequests[environment.id] == nil, "a settled stop is not kept as the recovery for a later problem")
        #expect(!model.retryAvailable(for: environment.id))
        // A problem the environment reports on its own must not find that stop behind Try again.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .needsAttention(.guestNotReachable(environment.id))))
        await model.refreshStatus(of: environment.id)
        model.perform(.retry, for: environment.id)
        try await Task.sleep(for: .milliseconds(50))
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { true } else { false } }
        #expect(stops.count == 1, "no second shutdown the user never asked for")
    }

    @Test func aFullRefreshWithdrawsTheRequestTheOutcomeItSettledWouldReplay() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // The stop reports an unresolved outcome and the check that follows still reports one,
        // so only a whole-dashboard reconciliation can settle it.
        await backend.script("stopEnvironment", .fail(error: .operationOutcomeUnknown(OperationID())))
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .needsAttention(.operationOutcomeUnknown(OperationID()))))
        model.stop(environment.id)
        await waitUntil({ model.operations.isEmpty && model.lastRequests[environment.id] != nil && model.lastErrors[environment.id] != nil },
                        "the stop to end with its outcome unresolved")
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await model.refresh()
        #expect(model.lastErrors[environment.id] == nil, "the reconciliation answered the outcome")
        #expect(model.lastRequests[environment.id] == nil, "so the stop is no longer what Try again would replay")
        #expect(!model.retryAvailable(for: environment.id))
    }

    @Test func aFailedCheckAfterAStopStillLeavesAControlThatWorks() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // `.runtimeStarting` offers Retry and Dismiss; the state is unread, so Dismiss is
        // deliberately refused, and the reconciliation guard used to refuse Retry as well.
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        await backend.script("environmentStatus", .fail(error: .runtimeStarting))
        model.stop(environment.id)
        await waitUntil({ model.operations.isEmpty && model.lastErrors[environment.id] == .runtimeStarting },
                        "the failed check to be what the card shows")
        #expect(model.reconciling.contains(environment.id), "the development Mac's state is still unread")
        let card = try #require(model.cardStates().first)
        #expect(card.recovery?.options.contains { $0.availability == .enabled } == true, "the card keeps one control the user can press")
        // …and it answers the check with another check, never by replaying the shutdown.
        await backend.script("environmentStatus", .succeed())
        model.perform(.retry, for: environment.id)
        await waitUntil({ model.statuses[environment.id] != nil }, "the second check to answer")
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { true } else { false } }
        #expect(stops.count == 1, "Try again inspected rather than replayed the stop")
    }

    @Test func aForceStopRefusedBeforeAcceptanceKeepsTheEscalationOffered() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        model.stop(environment.id)
        await waitUntil({ model.operations.isEmpty && !model.reconciling.contains(environment.id) }, "the failed graceful stop to be reconciled")
        #expect(model.canForceStop(environment.id), "a graceful stop the runtime took on and could not finish")
        // The escalation is refused before the runtime accepts it, so Tart was never asked:
        // that says nothing about the shutdown that did not happen.
        await backend.script("stopEnvironment", .refuse(error: .runtimeStarting))
        model.forceStop(environment.id)
        // The check that follows the refusal is what republishes the status, and the state it
        // reads back is what the escalation is judged against.
        await waitUntil({ model.operations.isEmpty && !model.reconciling.contains(environment.id) && model.lastErrors[environment.id] == .runtimeStarting },
                        "the refused escalation and the check after it")
        #expect(model.canForceStop(environment.id), "the graceful failure it escalates from still stands")
        #expect(!model.retryAvailable(for: environment.id), "and a force-stop is never replayed by the generic Retry")
    }

    @Test func aStopIsRefusedUntilTheAppHasReconciled() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        model.stop(environment.id)
        await waitUntil({ model.operations.isEmpty && !model.reconciling.contains(environment.id) }, "the failed graceful stop to be reconciled")
        // The connection goes away while nothing is in flight. The launch state changes at
        // once, the statuses stay cached while the reconciliation that replaces them runs, and
        // a Stop the view had already rendered is a callback queued over that stale snapshot.
        model.connectionInterrupted(RuntimeConnectionInterrupted())
        #expect(model.statuses[environment.id]?.vm == .running, "the pre-disconnection snapshot is still what the card holds")
        model.stop(environment.id)
        model.forceStop(environment.id)
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { true } else { false } }
        #expect(stops.count == 1, "no mutation goes out over state from before the loss")
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
        // The check that follows the loss is what settles it: the outcome is no longer unknown
        // and the environment is no longer under reconciliation. The request it would have
        // replayed is withdrawn by that same answer, so it is not what this waits on.
        await waitUntil({ model.operations.isEmpty && model.unknownOutcomes.isEmpty && !model.reconciling.contains(environment.id) },
                        "the interrupted start to be reconciled")
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
        // The poll that follows a recovered operation can settle the outcome from an answer
        // taken before the scripted status landed, and that one still names the operation:
        // the card reads "Stopped" only once an answer without it has been read back.
        await waitUntil {
            model.unknownOutcomes.isEmpty && model.statuses[environment.id]?.inFlightOperation == nil
        }
        #expect(model.cardStates().first?.statusText == "Stopped")
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { true } else { false } }
        #expect(stops.count == 1, "never replayed")
    }

    /// A whole-dashboard check reads every listed environment's status, so it answers an
    /// unresolved outcome exactly as a per-card inspection does. Leaving the error behind
    /// would keep `canMutate` refusing everything and hold the card on "Checking environment"
    /// until the user inspected the same environment a second time by hand.
    @Test func aFullRefreshSettlesAnUnknownOutcomeAPerCardCheckWouldHaveSettled() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let unresolved = OperationID()
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        // The stop's outcome is unresolved, and the status that follows it still says so, so
        // the automatic inspection cannot settle it.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .needsAttention(.operationOutcomeUnknown(unresolved))))
        await backend.script("stopEnvironment", .fail(error: .operationOutcomeUnknown(unresolved)))
        model.stop(environment.id)
        await waitUntil { model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.lastErrors[environment.id] == .operationOutcomeUnknown(unresolved))
        #expect(!model.canMutate(environment.id), "the outcome the runtime reported is still open")

        // The runtime has since established the state.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await model.refresh()
        #expect(model.lastErrors[environment.id] == nil, "the answered outcome is not left behind")
        #expect(model.canMutate(environment.id), "so the card is not held on Checking environment")
        #expect(model.cardStates().first?.availability(of: .stop) == .enabled)
    }

    /// Reconciliation that establishes the state ends the offer to replay what was in flight,
    /// the same rule a completed operation and a dismissal already apply. A request kept past
    /// it becomes the recovery for whatever a later status reports on its own.
    @Test func aStopSettledByReconciliationIsNoLongerWhatTryAgainReplays() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let unresolved = OperationID()
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .needsAttention(.operationOutcomeUnknown(unresolved))))
        await backend.script("stopEnvironment", .fail(error: .operationOutcomeUnknown(unresolved)))
        model.stop(environment.id)
        await waitUntil { model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.lastRequests[environment.id] != nil)

        // The VM is still running and nothing is unresolved: the stop did not happen, but the
        // state is known, so there is no failure left to replay.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        model.perform(.inspectState, for: environment.id)
        await waitUntil { model.lastErrors[environment.id] == nil }
        #expect(model.lastRequests[environment.id] == nil, "the settled stop is not carried forward")
        #expect(!model.retryAvailable(for: environment.id))
        model.perform(.retry, for: environment.id)
        try await Task.sleep(for: .milliseconds(100))
        let stops = await backend.receivedRequests.filter { if case .stopEnvironment = $0 { true } else { false } }
        #expect(stops.count == 1, "Try again over a later problem never resends the reconciled stop")
    }

    /// A successful inspection answers the query that failed, not the shutdown that did not
    /// happen. The stop's own failure comes back so the warned force-stop is never the only
    /// thing on a card that shows nothing to escalate from.
    @Test func theStopFailureComesBackWhenItsFailedStatusQueryIsAnswered() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await runningEnvironment(backend)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        let queryFailure = GuesthouseError.runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))
        await backend.script("stopEnvironment", .fail(error: .gracefulStopTimedOut(environment.id)))
        await backend.script("environmentStatus", .fail(error: queryFailure))
        model.stop(environment.id)
        // The query that follows the stop fails, so it settles nothing: the environment stays
        // under reconciliation, which is the state these assertions are about. The wait is on
        // the query's own failure having replaced the stop's, since that is what is asserted —
        // the stop's failure lands first, so waiting for "some error" would arrive too early.
        await waitUntil({ model.operations.isEmpty && model.statuses[environment.id] == nil && model.lastErrors[environment.id] == queryFailure },
                        "the failed check to be what the card shows")
        // The failed query left no status, so while the state is unread the query's own
        // failure is what the card shows and no destructive escalation is offered over it.
        #expect(model.statuses[environment.id] == nil)
        #expect(model.lastErrors[environment.id] != .gracefulStopTimedOut(environment.id), "the query's failure overwrote the stop's")
        #expect(!model.canForceStop(environment.id), "the state was never read back")

        await backend.script("environmentStatus", .succeed())
        model.perform(.inspectState, for: environment.id)
        // The inspection is what restores the stop's own failure, so the wait names that and
        // not merely a status coming back: another check can answer first.
        await waitUntil({
            model.statuses[environment.id] != nil && model.canMutate(environment.id)
                && model.lastErrors[environment.id] == .gracefulStopTimedOut(environment.id)
        }, "the inspection that restores the stop's failure")
        #expect(model.lastErrors[environment.id] == .gracefulStopTimedOut(environment.id), "the shutdown that did not happen is what the card explains")
        #expect(model.canForceStop(environment.id), "and the escalation is shown with the failure it escalates from")
    }
}
