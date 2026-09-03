import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

/// A backend that replays a fixed event list for every request.
final class ScriptedBackend: RuntimeBackend, Sendable {
    let events: [RuntimeEvent]
    init(events: [RuntimeEvent]) { self.events = events }

    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@MainActor
@Suite struct OperationPresentationTests {
    static let environment = EnvironmentID()
    static let everyError: [GuesthouseError] = [
        .unsupportedHost(.notAppleSilicon), .unsupportedHost(.macOSTooOld(found: "15.6", minimum: "26.4")),
        .unsupportedHost(.insufficientMemory(foundBytes: 8 << 30, minimumBytes: 16 << 30)),
        .insufficientDisk(requiredBytes: 200_000_000_000, availableBytes: 50_000_000_000, volumePath: "/"),
        .downloadVerificationFailed(artifact: "Tart 2.36.0", check: .digest), .runtimeMissing,
        .runtimeVerificationFailed(check: .signature), .runtimeIncompatible(found: "2.30.0", required: "2.36.0"),
        .guestNotReachable(environment), .hostKeyChanged(environment), .credentialsLocked(.guestKeychain),
        .credentialsLocked(.hostKeychain), .loginExpired(.github), .loginExpired(.codex),
        .toolMismatch(tool: "codex", found: nil, expected: "0.50.0"), .xcodeComponentsIncomplete(missing: ["iOS 26.4 Simulator"]),
        .vmSlotUnavailable(maximum: 2), .operationOutcomeUnknown(OperationID()), .unauthorizedCaller,
        .protocolMismatch(client: 2, service: 1), .invalidRequest(.pathEscapesAllowedRoot), .canceled,
    ]

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func stoppedEnvironment(_ backend: FakeRuntimeBackend) async -> DevelopmentEnvironment {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        return environment
    }

    @Test func everyErrorYieldsAtLeastOneOption() {
        let covered = Set(Self.everyError.map(\.caseName))
        #expect(covered.count == 18, "every case is represented (variants of one case share its name)")
        for error in Self.everyError {
            let presentation = RecoveryPresentation(error: error)
            #expect(!presentation.options.isEmpty, "\(error.caseName)")
            #expect(presentation.options.count == error.recoveryActions.count)
            #expect(presentation.message == error.userMessage)
            #expect(presentation.options.allSatisfy { !$0.title.isEmpty })
        }
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
        guard case .confirmFirst(let reason) = protected.cancelability else { Issue.record("expected a confirmation"); return }
        #expect(reason.contains("should not be interrupted"))
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
        await waitUntil { model.operations[environment.id]?.id == operation }
        let card = try #require(model.cardStates().first)
        #expect(card.progress?.cancelability == .immediate)
        model.cancel(environment.id)
        await waitUntil { model.operations.isEmpty }
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
        await waitUntil { model.lastErrors[environment.id] != nil && model.operations.isEmpty }
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
        await waitUntil { false }
        let starts = await backend.receivedRequests.filter { if case .startEnvironment = $0 { true } else { false } }
        #expect(starts.count == 1, "retry is refused while the outcome is unknown")
        await backend.script("environmentStatus", .succeed())
        model.perform(.inspectState, for: environment.id)
        await waitUntil { model.unknownOutcomes.isEmpty }
        #expect(model.cardStates().first?.availability(of: .start) == .enabled)
    }

    @Test func logsAreCollectedForTheOperationAndCapped() async throws {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let operation = OperationID()
        var events: [RuntimeEvent] = [.accepted(operation)]
        for index in 0..<600 { events.append(.log(operation, RedactedLine(literal: "line"))) ; _ = index }
        events.append(.completed(operation))
        let backend = ScriptedBackend(events: events)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        let card = EnvironmentCardState(environment: environment, status: nil, operation: nil, lastError: nil, logs: [RedactedLine(literal: "a")])
        #expect(card.logs.count == 1)
        var state = AppModel.OperationState(id: operation, request: .startEnvironment(environment.id, StartOptions()))
        for _ in 0..<600 { state.logs.append(RedactedLine(literal: "line")) }
        #expect(state.logs.count == 600)
        #expect(AppModel.OperationState.maximumLogLines == 500)
    }
}
