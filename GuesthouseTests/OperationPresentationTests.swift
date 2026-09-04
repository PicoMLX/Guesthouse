import Foundation
import GuesthouseCore
import SwiftUI
import Testing
@testable import Guesthouse

/// A backend that replays a fixed event list per request case name.
final class ScriptedBackend: RuntimeBackend, Sendable {
    let events: [String: [RuntimeEvent]]
    init(_ events: [String: [RuntimeEvent]]) { self.events = events }

    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events[request.caseName] ?? [] { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@MainActor
@Suite struct OperationPresentationTests {
    static let environment = EnvironmentID()
    /// One value per `GuesthouseError` case: the presentation contract is only as covered as
    /// this list, so it is checked against the complete case inventory below.
    static let everyError: [GuesthouseError] = [
        .unsupportedHost(.notAppleSilicon), .unsupportedHost(.macOSTooOld(found: "15.6", minimum: "26.4")),
        .unsupportedHost(.insufficientMemory(foundBytes: 8 << 30, minimumBytes: 16 << 30)),
        .unsupportedHost(.architectureUnknown),
        .insufficientDisk(requiredBytes: 200_000_000_000, availableBytes: 50_000_000_000, volumePath: "/"),
        .downloadVerificationFailed(artifact: "Tart 2.36.0", check: .digest), .runtimeMissing,
        .runtimeStarting, .runtimeStateUnavailable(reason: "disk full"),
        .runtimeStorageUnavailable(reason: "the location is not writable", problem: .unwritable),
        .runtimeStorageUnavailable(reason: "something else occupies the location", problem: .unsafeLocation),
        .runtimeVerificationFailed(check: .signature), .runtimeIncompatible(found: "2.30.0", required: "2.36.0"),
        .guestNotReachable(environment), .hostKeyChanged(environment), .credentialsLocked(.guestKeychain),
        .credentialsLocked(.hostKeychain), .loginExpired(.github), .loginExpired(.codex),
        .toolMismatch(tool: "codex", found: nil, expected: "0.50.0"), .xcodeComponentsIncomplete(missing: ["iOS 26.4 Simulator"]),
        .vmSlotUnavailable(maximum: 2), .environmentNotFound(environment), .environmentAlreadyRunning(environment),
        .anotherEnvironmentRunning(environment), .environmentPreserved(environment),
        .vmOwnershipUncertain(environment), .gracefulStopTimedOut(environment),
        .operationInFlight(OperationID()), .operationOutcomeUnknown(OperationID()), .unauthorizedCaller,
        .protocolMismatch(client: 2, service: 1), .invalidRequest(.pathEscapesAllowedRoot),
        .xcodeSelectionRejected(.notXcode), .canceled,
    ]

    /// Every case `GuesthouseError.caseName` can return. Adding a case is a compile error
    /// there, and this list is what makes it a test failure here.
    static let everyCaseName: Set<String> = [
        "unsupportedHost", "insufficientDisk", "downloadVerificationFailed", "runtimeMissing",
        "runtimeStarting", "runtimeStateUnavailable", "runtimeStorageUnavailable",
        "runtimeVerificationFailed", "runtimeIncompatible", "guestNotReachable", "hostKeyChanged",
        "credentialsLocked", "loginExpired", "toolMismatch", "xcodeComponentsIncomplete",
        "vmSlotUnavailable", "environmentNotFound", "environmentAlreadyRunning",
        "anotherEnvironmentRunning", "environmentPreserved", "vmOwnershipUncertain",
        "gracefulStopTimedOut", "operationInFlight", "operationOutcomeUnknown", "unauthorizedCaller",
        "protocolMismatch", "invalidRequest", "xcodeSelectionRejected", "canceled",
    ]

    /// Waits for a condition, and reports when it never became true: a wait that silently
    /// times out leaves the assertions after it testing something else.
    func waitUntil(_ condition: @MainActor () -> Bool, _ description: String = "condition", sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        if !condition() { Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation) }
    }

    func stoppedEnvironment(_ backend: FakeRuntimeBackend) async -> DevelopmentEnvironment {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        return environment
    }

    @Test func everyErrorYieldsAtLeastOneOption() {
        let covered = Set(Self.everyError.map(\.caseName))
        #expect(covered == Self.everyCaseName, "every error case is represented in the presentation test")
        for error in Self.everyError {
            let presentation = RecoveryPresentation(error: error)
            #expect(!presentation.options.isEmpty, "\(error.caseName)")
            #expect(presentation.options.count == error.recoveryActions.count)
            #expect(presentation.message == error.userMessage)
            #expect(presentation.options.allSatisfy { !$0.title.isEmpty })
        }
    }

    @Test func unknownOutcomesOfferOnlyACheck() {
        #expect(RecoveryPresentation(unknownOutcomeOf: OperationID()).options.map(\.action) == [.inspectState])
    }

    @Test func retryIsDisabledWhenThereIsNothingToReplay() {
        let presentation = RecoveryPresentation(error: .guestNotReachable(EnvironmentID()), retryAvailable: false)
        guard let retry = presentation.options.first(where: { $0.action == .retry }) else { Issue.record("no retry option"); return }
        guard case .disabled = retry.availability else { Issue.record("retry should be disabled without a request"); return }
        #expect(OperationProgressPresentation(phase: nil, request: .startEnvironment(EnvironmentID(), StartOptions()), accepted: false).cancelability == .unavailable(reason: "Waiting for the runtime to accept the operation."))
        #expect(OperationProgressPresentation(recoveredOperation: OperationID()).cancelability == .immediate)
    }

    @Test func aFailedStatusReplyKeepsTheOutcomeUnknown() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.start(environment.id)
        await waitUntil { model.operations[environment.id] == nil && !model.reconciling.contains(environment.id) }
        #expect(model.unknownOutcomes[environment.id] != nil, "a failed status reply settles nothing")
        #expect(model.cardStates().first?.outcomeUnknown == true)
        await backend.script("environmentStatus", .succeed())
        await model.refresh()
        #expect(model.unknownOutcomes.isEmpty, "a full reconciliation that read the status settles it")
    }

    @Test func cancelWaitsForTheAcceptedIDAndReportsRefusals() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(30))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .hang)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        #expect(model.cardStates().first?.progress?.cancelability == .unavailable(reason: "Waiting for the runtime to accept the operation."))
        model.cancel(environment.id)
        await waitUntil { model.operations[environment.id]?.acceptedID != nil }
        let accepted = try #require(model.operations[environment.id]?.acceptedID)
        #expect(model.cardStates().first?.progress?.cancelability == .immediate)
        await backend.script("cancelOperation", .fail(error: .operationInFlight(accepted)))
        model.cancel(environment.id)
        await waitUntil { model.lastErrors[environment.id] != nil }
        #expect(model.lastErrors[environment.id] == .operationInFlight(accepted), "a refused cancellation is shown")
        await backend.script("cancelOperation", .succeed())
        model.cancel(environment.id)
        await waitUntil { model.operations[environment.id] == nil }
        let cancels = await backend.receivedRequests.filter { if case .cancelOperation = $0 { return true }; return false }
        #expect(cancels.allSatisfy { $0 == .cancelOperation(accepted) }, "only the accepted id is ever canceled")
        #expect(cancels.count == 2)
    }

    @Test func aStatusReportedOperationCanBeCanceledByItsID() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let recovered = OperationID()
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: recovered))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        let card = try #require(model.cardStates().first)
        #expect(card.progress != nil, "a recovered operation gets progress and Cancel controls")
        model.cancel(environment.id)
        var requests: [RuntimeRequest] = []
        for _ in 0..<400 {
            requests = await backend.receivedRequests
            if requests.contains(.cancelOperation(recovered)) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests.contains(.cancelOperation(recovered)))
    }

    @Test func retryWaitsForTheStatusCheckThatFollowsAFailure() async throws {
        // A slow status reply keeps the reconciliation window open long enough to observe it
        // on a loaded machine.
        let backend = FakeRuntimeBackend(delay: .milliseconds(150))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil { model.reconciling.contains(environment.id) }
        #expect(model.cardStates().first?.recovery?.options.first { $0.action == .retry }?.availability != .enabled, "no retry while the status is being read")
        model.perform(.retry, for: environment.id)
        await waitUntil { model.reconciling.isEmpty }
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { return true }; return false }
        #expect(starts.count == 1, "the retry during reconciliation was refused")
        #expect(model.cardStates().first?.recovery?.options.first { $0.action == .retry }?.availability == .enabled)
    }

    @Test func unknownOutcomesNeverOfferRetry() {
        let unknown = RecoveryPresentation(unknownOutcomeOf: OperationID())
        #expect(unknown.title == "Checking environment")
        #expect(unknown.outcomeUnknown)
        #expect(!unknown.options.contains { $0.action == .retry })
        #expect(unknown.options.contains { $0.action == .inspectState && $0.availability == .enabled })
        let error = RecoveryPresentation(error: .operationOutcomeUnknown(OperationID()))
        #expect(!error.options.contains { $0.action == .retry })
        #expect(error.title == "Checking environment")
    }

    @Test func progressIsDeterminateOnlyWithAFractionAndConfirmsForProtectedPhases() {
        let request = RuntimeRequest.startEnvironment(Self.environment, StartOptions())
        let measured = OperationProgressPresentation(phase: ProgressPhase(kind: .waitingForNetwork, fraction: 0.3), request: request)
        #expect(measured.fraction == 0.3)
        #expect(measured.cancelability == .immediate)
        #expect(measured.title == EnvironmentCardState.describe(ProgressPhase(kind: .waitingForNetwork)))
        let protected = OperationProgressPresentation(phase: ProgressPhase(kind: .copying, cancelable: false), request: request)
        #expect(protected.fraction == nil)
        guard case .deferred(let reason) = protected.cancelability else { Issue.record("expected a deferred cancellation"); return }
        // The runtime defers the request to the next cancelable phase rather than interrupting
        // this one, so the confirmation must not promise an immediate stop or warn about repair.
        #expect(reason.contains("cannot be interrupted"))
        #expect(reason.contains("next step that can be"))
        #expect(!reason.contains("needing repair"))
        let early = OperationProgressPresentation(phase: nil, request: request)
        #expect(early.title == "Starting the development Mac…")
    }

    @Test func cancelSendsTheAcceptedOperationID() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await stoppedEnvironment(backend)
        let operation = OperationID()
        await backend.useOperationID(operation, forNext: "startEnvironment")
        await backend.script("startEnvironment", .hang)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        // The runtime's id lands in `acceptedID`; the provisional `id` the app reserved with
        // is never replaced and nothing is ever canceled by it.
        await waitUntil({ model.operations[environment.id]?.acceptedID == operation }, "the runtime's id to be accepted")
        #expect(model.operations[environment.id]?.id != operation)
        let card = try #require(model.cardStates().first)
        #expect(card.progress?.cancelability == .immediate)
        model.cancel(environment.id)
        await waitUntil({ model.operations.isEmpty }, "the canceled operation to end")
        #expect(model.lastErrors[environment.id] == .canceled)
        #expect(await backend.receivedRequests.contains(.cancelOperation(operation)))
    }

    @Test func retryResendsTheLastRequest() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await stoppedEnvironment(backend)
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        // Retry becomes available only once the status check that follows the failure has
        // answered: nothing is replayed over a state that was not read back.
        await waitUntil { model.lastErrors[environment.id] != nil && model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        let failed = try #require(model.cardStates().first)
        #expect(failed.recovery?.options.contains { $0.action == .retry && $0.availability == .enabled } == true)
        await backend.script("startEnvironment", .succeed(status: EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready)))
        model.perform(.retry, for: environment.id)
        await waitUntil { model.statuses[environment.id]?.vm == .running && model.operations.isEmpty }
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }
        #expect(starts.count == 2)
        #expect(model.cardStates().first?.recovery == nil)
        model.perform(.cancel, for: environment.id)
        #expect(model.lastErrors[environment.id] == nil)
    }

    @Test func interruptionMarksTheOutcomeUnknownUntilAStatusQuerySucceeds() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await stoppedEnvironment(backend)
        await backend.script("startEnvironment", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.launchState == .ready)
        // The status query after the interruption fails too, so the outcome stays unknown.
        await backend.script("environmentStatus", .disconnect())
        model.start(environment.id)
        await waitUntil { model.operations.isEmpty && model.unknownOutcomes[environment.id] != nil }
        let card = try #require(model.cardStates().first)
        #expect(card.outcomeUnknown)
        #expect(card.statusText == "Checking environment…")
        #expect(card.recovery?.title == "Checking environment")
        #expect(card.recovery?.options.contains { $0.action == .retry } == false)
        #expect(card.availability(of: .start) == .disabled(reason: "Checking environment"))
        model.perform(.retry, for: environment.id)
        // Long enough for a request the guard should have refused to reach the fake.
        try? await Task.sleep(for: .milliseconds(100))
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }
        #expect(starts.count == 1, "retry is refused while the outcome is unknown")
        await backend.script("environmentStatus", .succeed())
        // The interrupted start is still marked in flight in the runtime's own status; the
        // inspection is what settles it, so the runtime is told the VM is idle again first.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        model.perform(.inspectState, for: environment.id)
        // The inspection is an operation of its own: Start comes back once it has finished,
        // not the moment the unknown outcome is settled.
        await waitUntil { model.unknownOutcomes.isEmpty && model.operations.isEmpty && model.reconciling.isEmpty }
        #expect(model.cardStates().first?.availability(of: .start) == .enabled)
    }

    /// The bound belongs to the model, so it is driven through one: an operation that logs
    /// more than the cap must leave the newest lines behind, not the oldest.
    @Test func theModelKeepsOnlyTheNewestLogLinesOfAnOperation() async throws {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let operation = OperationID()
        let total = 600
        let lines = Redactor().redact(lines: (0..<total).map { "line \($0)" })
        let backend = ScriptedBackend([
            "listEnvironments": [.environments([environment])],
            "environmentStatus": [.status(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))],
            "startEnvironment": [.accepted(operation)] + lines.map { .log(operation, $0) } + [.completed(operation)],
        ])
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil({ model.operations.isEmpty && model.lastLogs[environment.id] != nil }, "the operation to finish")
        let kept = try #require(model.lastLogs[environment.id])
        #expect(kept.count == AppModel.OperationState.maximumLogLines)
        #expect(kept.first?.text == "line \(total - AppModel.OperationState.maximumLogLines)")
        #expect(kept.last?.text == "line \(total - 1)")
        #expect(model.cardStates().first?.logs == kept, "the card shows what the model kept")
    }

    @Test func aRefusedCancellationIsShownWhileTheStatusAlsoNeedsAttention() async throws {
        let backend = FakeRuntimeBackend(delay: .milliseconds(20))
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        // A start that is running while the guest has no confirmed address: the status already
        // needs attention, which must not hide what the cancellation just reported.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .needsAttention(.guestNotReachable(environment.id))))
        await backend.script("startEnvironment", .hang)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil({ model.operations[environment.id]?.acceptedID != nil }, "the operation to be accepted")
        let accepted = try #require(model.operations[environment.id]?.acceptedID)
        await backend.script("cancelOperation", .fail(error: .operationInFlight(accepted)))
        model.cancel(environment.id)
        await waitUntil({ model.lastErrors[environment.id] != nil }, "the refusal to be recorded")
        #expect(model.cardStates().first?.attention == .operationInFlight(accepted), "the refusal is what the card explains")
        await backend.script("cancelOperation", .succeed())
        model.cancel(environment.id)
        await waitUntil({ model.operations.isEmpty }, "the canceled operation to end")
    }

    @Test func aStatusReportedUnknownOutcomeIsPresentedAsUnknown() throws {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let status = EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .needsAttention(.operationOutcomeUnknown(OperationID())))
        let card = EnvironmentCardState(environment: environment, status: status, operation: nil, lastError: nil)
        #expect(card.outcomeUnknown, "the runtime's own unresolved record is the same unknown state")
        #expect(card.isBusy)
        #expect(card.statusText == "Checking environment…")
        #expect(card.recovery?.title == "Checking environment")
        #expect(card.availability(of: .start) == .disabled(reason: "Checking environment"))
    }

    @Test func aProblemTheStatusKeepsReportingCannotBeDismissed() throws {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let status = EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .needsAttention(.guestNotReachable(environment.id)))
        let reported = EnvironmentCardState(environment: environment, status: status, operation: nil, lastError: nil)
        let dismiss = try #require(reported.recovery?.options.first { $0.action == .cancel })
        guard case .disabled(let reason) = dismiss.availability else { Issue.record("Dismiss should not claim to clear a status error"); return }
        #expect(reason.contains("still reports this"))
        let local = EnvironmentCardState(environment: environment, status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready), operation: nil, lastError: .guestNotReachable(environment.id))
        #expect(local.recovery?.options.first { $0.action == .cancel }?.availability == .enabled, "a failure this window recorded is dismissible")
    }

    @Test func deletingAnEnvironmentIsOfferedAsDestructive() throws {
        let presentation = RecoveryPresentation(error: .vmSlotUnavailable(maximum: 2))
        let delete = try #require(presentation.options.first { $0.action == .deleteEnvironment })
        #expect(delete.isDestructive)
        #expect(delete.buttonRole == .destructive, "the role reaches the rendered button")
        #expect(presentation.options.filter { $0.action != .deleteEnvironment }.allSatisfy { $0.buttonRole == nil })
    }

    @Test func recoveryControlsWrapInsteadOfOverflowingTheCard() {
        // Four options at a card's narrow column: the row breaks rather than truncating.
        let widths: [CGFloat] = [120, 150, 110, 130]
        #expect(WrappingRows.rows(of: widths, spacing: 8, in: 300) == [[0, 1], [2, 3]])
        #expect(WrappingRows.rows(of: widths, spacing: 8, in: 1_000) == [[0, 1, 2, 3]])
        // A control wider than the row still gets one of its own rather than being dropped.
        #expect(WrappingRows.rows(of: [400, 50], spacing: 8, in: 100) == [[0], [1]])
        #expect(WrappingRows.rows(of: [], spacing: 8, in: 300).isEmpty)
    }
}
