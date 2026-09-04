import Foundation
import GuesthouseCore
import SwiftUI
import Synchronization
import Testing
@testable import Guesthouse

/// A backend that replays a fixed event list per request case name.
final class ScriptedBackend: RuntimeBackend, Sendable {
    let events: [String: [RuntimeEvent]]
    init(_ events: [String: [RuntimeEvent]]) { self.events = events }

    /// The queries answered from fixed data, one event list replayed for every operation: the
    /// shape a diagnostics fixture needs, expressed in the same script.
    init(events: [RuntimeEvent], environments: [DevelopmentEnvironment] = [], status: EnvironmentStatus? = nil) {
        var script: [String: [RuntimeEvent]] = [:]
        script["runtimeVersion"] = [.runtimeVersion(RuntimeVersionInfo(serviceVersion: "9.9", serviceBuild: "1"))]
        script["listEnvironments"] = [.environments(environments)]
        if let status { script["environmentStatus"] = [.status(status)] }
        for name in ["startEnvironment", "stopEnvironment", "cancelOperation", "importXcode"] { script[name] = events }
        self.events = script
    }

    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        AsyncThrowingStream { continuation in
            if let scripted = events[request.caseName] {
                for event in scripted { continuation.yield(event) }
            } else if case .environmentStatus(let id) = request {
                continuation.yield(.status(EnvironmentStatus(environmentID: id, vm: .stopped, readiness: .ready)))
            }
            continuation.finish()
        }
    }
}

/// Forwards to a fake backend, except for the requests a test chooses to hold: their replies
/// are released by index, so two answers crossing on the wire is a case a test can state
/// rather than a race it has to hope for.
final class HeldReplyBackend: RuntimeBackend, Sendable {
    private let inner: FakeRuntimeBackend
    private let replies = Mutex<[@Sendable () -> Void]>([])
    private let events: @Sendable (RuntimeRequest) -> [RuntimeEvent]?

    /// - Parameter events: the reply to hold for a request, or nil to let it through.
    init(_ inner: FakeRuntimeBackend, holding events: @escaping @Sendable (RuntimeRequest) -> [RuntimeEvent]?) {
        self.inner = inner
        self.events = events
    }

    var heldReplies: Int { replies.withLock { $0.count } }

    /// Delivers the reply held at `index`; 0 is the oldest still held.
    func release(_ index: Int) {
        let reply = replies.withLock { held -> (@Sendable () -> Void)? in
            held.indices.contains(index) ? held.remove(at: index) : nil
        }
        reply?()
    }

    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        guard let scripted = events(request) else { return inner.send(request) }
        return AsyncThrowingStream { continuation in
            replies.withLock { held in
                held.append {
                    for event in scripted { continuation.yield(event) }
                    continuation.finish()
                }
            }
        }
    }

    nonisolated func connectionInterruptions() -> AsyncStream<RuntimeConnectionInterrupted> {
        inner.connectionInterruptions()
    }
}

/// Forwards to a fake backend but holds one request's *loss*: the stream throws only when the
/// test releases it, so a reconciliation can run to completion between the send and the
/// disconnection it reports.
final class HeldLossBackend: RuntimeBackend, Sendable {
    private let inner: FakeRuntimeBackend
    private let losses = Mutex<[@Sendable () -> Void]>([])
    private let holds: @Sendable (RuntimeRequest) -> Bool

    init(_ inner: FakeRuntimeBackend, holding holds: @escaping @Sendable (RuntimeRequest) -> Bool) {
        self.inner = inner
        self.holds = holds
    }

    var heldLosses: Int { losses.withLock { $0.count } }

    /// Ends the oldest held stream with a dropped connection.
    func releaseLoss() {
        let loss = losses.withLock { held -> (@Sendable () -> Void)? in held.isEmpty ? nil : held.removeFirst() }
        loss?()
    }

    nonisolated func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        guard holds(request) else { return inner.send(request) }
        return AsyncThrowingStream { continuation in
            losses.withLock { $0.append { continuation.finish(throwing: RuntimeConnectionInterrupted()) } }
        }
    }

    nonisolated func connectionInterruptions() -> AsyncStream<RuntimeConnectionInterrupted> {
        inner.connectionInterruptions()
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

    func waitUntil(_ condition: @MainActor () async -> Bool, _ description: String = "condition", sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<600 where await !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        if await !condition() { Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation) }
    }

    func stoppedEnvironment(_ backend: FakeRuntimeBackend) async -> DevelopmentEnvironment {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        return environment
    }

    @Test func aRuntimeReportedUnknownOutcomeBlocksStartsElsewhere() async throws {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        let unresolved = OperationID()
        await backend.setEnvironments([first, second])
        // The runtime itself says the first environment's last mutation is unresolved.
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .needsAttention(.operationOutcomeUnknown(unresolved))))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.globalStartBlock != nil, "an unresolved mutation is not a state to start a second development Mac over")
        guard case .disabled = try #require(model.cardStates().last).availability(of: .start) else {
            Issue.record("expected Start disabled on the other card"); return
        }
        model.start(second.id)
        #expect(model.operations.isEmpty, "a refused start sends nothing")
    }

    @Test func anUnknownOutcomeBlocksStartsEvenWhenItsEnvironmentIsUnlisted() async throws {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.start(first.id)
        await waitUntil { model.unknownOutcomes[first.id] != nil }
        // The next listing no longer mentions the environment whose mutation is unresolved.
        await backend.setEnvironments([second])
        await backend.script("environmentStatus", .succeed())
        await model.refresh()
        #expect(model.unknownOutcomes[first.id] != nil, "the marker is kept for an environment the runtime stopped listing")
        let block = try #require(model.globalStartBlock, "an unresolved mutation blocks starts whether or not its environment is listed")
        #expect(block.contains("last operation"))
        guard case .disabled = try #require(model.cardStates().first).availability(of: .start) else {
            Issue.record("expected Start disabled on the remaining card"); return
        }
    }

    @Test func aTerminalUnknownOutcomeIsRememberedLikeALostStream() async throws {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        let unresolved = OperationID()
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        // The runtime could not persist the terminal result and says so as a normal failure.
        await backend.script("startEnvironment", .fail(error: .operationOutcomeUnknown(unresolved)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.start(first.id)
        await waitUntil { model.operations[first.id] == nil }
        #expect(model.unknownOutcomes[first.id] == unresolved, "a terminal failure that names an unresolved mutation is an unknown outcome")
        #expect(model.globalStartBlock != nil)
        model.start(second.id)
        #expect(model.operations.isEmpty, "no start is offered over a mutation whose result is unestablished")
    }

    @Test func anInspectionThatSettlesAnUnknownOutcomeClearsTheErrorThatReportedIt() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let unresolved = OperationID()
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .fail(error: .operationOutcomeUnknown(unresolved)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        // The inspection that follows the start answers with a normal, settled status, which
        // is exactly what establishes the outcome the failure said was unknown.
        // `reconciling` is entered before that inspection and left only when a status answers,
        // so this waits for the answer rather than for the operation to be removed.
        await waitUntil { model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.unknownOutcomes[environment.id] == nil, "the answer settled it")
        #expect(model.lastErrors[environment.id] == nil, "so the error that reported it unknown is settled too")
        let card = try #require(model.cardStates().first)
        #expect(!card.outcomeUnknown, "the card does not keep deriving an unknown outcome from a retained error")
        #expect(!card.isBusy, "nor stay on \"Checking environment\" after the check answered")
        #expect(card.availability(of: .start) == .enabled, "and Start returns without the user dismissing anything")
    }

    @Test func aStatusThatStillReportsAnUnknownOutcomeKeepsIt() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let unresolved = OperationID()
        await backend.setEnvironments([environment])
        // The check answers, but its answer is that the runtime cannot account for the
        // mutation either: that is its own news and is not cleared by the answer.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .needsAttention(.operationOutcomeUnknown(unresolved))))
        await backend.script("startEnvironment", .fail(error: .operationOutcomeUnknown(unresolved)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil { model.operations.isEmpty && !model.reconciling.contains(environment.id) }
        #expect(model.globalStartBlock != nil, "the runtime's own unresolved outcome still blocks every start")
        #expect(model.cardStates().first?.outcomeUnknown == true)
    }

    @Test func aFailedInspectionKeepsTheGlobalGuardStanding() async throws {
        let backend = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        await backend.setEnvironments([first, second])
        await backend.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        await backend.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready))
        // A start that fails normally, so nothing is left unknown, and then an inspection that
        // establishes nothing about the VM the start may have left running.
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(first.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        model.start(first.id)
        await waitUntil { model.operations[first.id] == nil && model.statuses[first.id] == nil }
        #expect(model.unknownOutcomes[first.id] == nil, "the operation itself reported a result")
        #expect(model.reconciling.contains(first.id), "but nothing is known about its VM")
        #expect(model.globalStartBlock != nil)
        model.start(second.id)
        #expect(model.operations.isEmpty, "no second development Mac is started over an unread VM")
        // A successful inspection is what ends the guard.
        await backend.script("environmentStatus", .succeed())
        await model.refreshStatus(of: first.id)
        #expect(!model.reconciling.contains(first.id))
        #expect(model.globalStartBlock == nil)
    }

    @Test func aSupersededInspectionDoesNotReplaceANewerAnswer() async throws {
        let fake = FakeRuntimeBackend()
        let environment = await stoppedEnvironment(fake)
        let older = EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: OperationID())
        let newer = EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready)
        // Nothing is held until the reconciliation is done; then the two checks answer in the
        // order the test releases them.
        let answers = Mutex<[[RuntimeEvent]]>([])
        let backend = HeldReplyBackend(fake) { request in
            guard case .environmentStatus = request else { return nil }
            return answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        answers.withLock { $0 = [[.status(older)], [.status(newer)]] }
        let superseded = Task { await model.refreshStatus(of: environment.id) }
        await waitUntil({ backend.heldReplies == 1 }, "the first check to be sent")
        let current = Task { await model.refreshStatus(of: environment.id) }
        await waitUntil({ backend.heldReplies == 2 }, "the second check to be sent")
        // The newer check answers first, and the older one only afterwards.
        backend.release(1)
        await current.value
        #expect(model.statuses[environment.id]?.vm == .running)
        backend.release(0)
        await superseded.value
        #expect(model.statuses[environment.id]?.vm == .running, "the older answer did not replace the newer one")
        #expect(model.statuses[environment.id]?.inFlightOperation == nil, "nor did it re-block the dashboard behind a finished operation")
    }

    @Test func aRefusedCancellationOfAnEndedOperationIsNotShown() async throws {
        let fake = FakeRuntimeBackend()
        let first = DevelopmentEnvironment(name: "First", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Second", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
        let ended = OperationID()
        let running = OperationID()
        await fake.setEnvironments([first, second])
        await fake.setStatus(EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready, inFlightOperation: ended))
        await fake.setStatus(EnvironmentStatus(environmentID: second.id, vm: .stopped, readiness: .ready, inFlightOperation: running))
        let backend = HeldReplyBackend(fake) { request in
            guard case .cancelOperation(let operation) = request else { return nil }
            return [.failed(operation, .operationInFlight(operation))]
        }
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.cancel(first.id)
        model.cancel(second.id)
        await waitUntil({ backend.heldReplies == 2 }, "both cancellations to be sent")
        // The first environment's operation reaches its own end while the refusals are still out.
        await fake.setStatus(EnvironmentStatus(environmentID: first.id, vm: .running, readiness: .ready))
        await model.refreshStatus(of: first.id)
        #expect(model.statuses[first.id]?.inFlightOperation == nil)
        // Released in order, so the refusal for the operation still in flight is the later of
        // the two: once it is on the card, the earlier one has had its turn.
        backend.release(0)
        backend.release(0)
        await waitUntil { model.lastErrors[second.id] != nil }
        #expect(model.lastErrors[first.id] == nil, "a refusal for work that has already ended is not news")
        #expect(model.cardStates().first?.attention == nil)
    }

    @Test func aRefusedCancellationClearsWhenItsOperationEnds() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await stoppedEnvironment(backend)
        let recovered = OperationID()
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, inFlightOperation: recovered))
        await backend.script("cancelOperation", .fail(error: .operationInFlight(recovered)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.cancel(environment.id)
        await waitUntil { model.lastErrors[environment.id] == .operationInFlight(recovered) }
        // The operation finishes on its own; the next inspection shows nothing in flight.
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready))
        await model.refreshStatus(of: environment.id)
        #expect(model.lastErrors[environment.id] == nil, "the refusal belonged to an operation that is over")
        #expect(model.cardStates().first?.attention == nil)
    }

    @Test func aFailedCheckOfAnUnknownOutcomeIsShownWithIt() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await stoppedEnvironment(backend)
        await backend.script("startEnvironment", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        let failure = GuesthouseError.runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))
        await backend.script("environmentStatus", .fail(error: failure))
        model.start(environment.id)
        // The operation's own tail also drops the status, so waiting on that alone can run
        // ahead of the check: the failure it records is what the panel has to name.
        await waitUntil {
            model.unknownOutcomes[environment.id] != nil && model.statuses[environment.id] == nil
                && model.lastErrors[environment.id] == failure
        }
        let recovery = try #require(model.cardStates().first?.recovery)
        #expect(recovery.outcomeUnknown, "the outcome stays unknown")
        #expect(recovery.message.contains(failure.userMessage), "the check's own failure is named, not hidden behind another Check button")
        #expect(recovery.options.map(\.action).contains(.inspectState))
        #expect(recovery.options.map(\.action).contains(.openSettings), "the failure's safe recovery is offered with it")
        #expect(!recovery.options.map(\.action).contains(.retry), "nothing that mutates is offered over an unknown outcome")
    }

    @Test func aFailedCheckKeepsTheCardsWayToAskAgain() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await stoppedEnvironment(backend)
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("environmentStatus", .fail(error: .runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))))
        await model.refreshStatus(of: environment.id)
        let recovery = try #require(model.cardStates().first?.recovery)
        let dismiss = try #require(recovery.options.first { $0.action == .cancel })
        guard case .disabled = dismiss.availability else {
            Issue.record("dismissing the check's own failure would leave the card no way to ask again"); return
        }
        // Activating it anyway leaves the panel, and its Check environment, in place.
        model.perform(.cancel, for: environment.id)
        let after = try #require(model.cardStates().first?.recovery)
        #expect(after.options.map(\.action).contains(.inspectState))
    }

    @Test func retryAfterAFailedCheckInspectsInsteadOfReplaying() async throws {
        let backend = FakeRuntimeBackend()
        let environment = await stoppedEnvironment(backend)
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        await waitUntil { model.operations[environment.id] == nil }
        // The check that follows the failed start fails too, with a retryable error.
        await backend.script("environmentStatus", .fail(error: .runtimeStarting))
        await model.refreshStatus(of: environment.id)
        #expect(model.statuses[environment.id] == nil, "the failed check removed the cached state")
        let startsBefore = await backend.receivedRequests.filter { if case .startEnvironment = $0 { return true }; return false }.count
        await backend.script("environmentStatus", .succeed())
        model.perform(.retry, for: environment.id)
        await waitUntil { model.statuses[environment.id] != nil }
        let startsAfter = await backend.receivedRequests.filter { if case .startEnvironment = $0 { return true }; return false }.count
        #expect(startsAfter == startsBefore, "the retry answered the failure the card shows: the check, not the old start")
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
        // A recovered operation carries no phase, and the runtime defers a cancellation during
        // a protected one, so Cancel is presented as the deferred case it may turn out to be.
        guard case .deferred = OperationProgressPresentation(recoveredOperation: OperationID()).cancelability else {
            Issue.record("a recovered operation's cancellation is not promised as immediate"); return
        }
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
        await waitUntil { model.operations[environment.id] == nil && model.unknownOutcomes[environment.id] != nil }
        #expect(model.unknownOutcomes[environment.id] != nil, "a failed status reply settles nothing")
        #expect(model.reconciling.contains(environment.id), "nor does it end the check the operation started")
        #expect(model.cardStates().first?.outcomeUnknown == true)
        await backend.script("environmentStatus", .succeed())
        await model.refresh()
        #expect(model.unknownOutcomes.isEmpty, "a full reconciliation that read the status settles it")
        #expect(model.reconciling.isEmpty, "and ends the check with it")
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
        // Accepted, but no step reported yet: `EnvironmentLifecycle.cancel` treats a missing
        // phase as deferred because the first phase of a start is protected, so Cancel asks
        // rather than promising to stop the operation now.
        #expect(model.cardStates().first?.progress?.cancelability == .deferred(reason: OperationProgressPresentation.unreportedPhaseReason))
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
        // No phase has been reported for the accepted operation yet, so Cancel is deferred.
        #expect(card.progress?.cancelability == .deferred(reason: OperationProgressPresentation.unreportedPhaseReason))
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

    @Test func aRefusedCancellationOfARecoveredOperationIsWhatTheCardShows() {
        // A recovered operation has no local record, so the card used to fall through to the
        // status's standing attention and the refusal never appeared: the user could believe
        // the cancellation they asked for had been accepted while the operation ran on.
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let status = EnvironmentStatus(
            environmentID: environment.id,
            vm: .running,
            readiness: .needsAttention(.guestNotReachable(environment.id)),
            inFlightOperation: OperationID()
        )
        let refusal = GuesthouseError.operationInFlight(OperationID())
        let card = EnvironmentCardState(environment: environment, status: status, operation: nil, lastError: refusal)
        #expect(card.attention == refusal, "the refusal this window just caused is the news")
        #expect(card.recovery?.message == refusal.userMessage)
    }

    @Test func aFailedCheckWithNothingButDismissStillOffersACheck() {
        // `.unauthorizedCaller` and `.invalidRequest` carry only Dismiss, and dismissing the
        // check's own failure is deliberately refused while the state is unread — so without
        // this the panel was a message with every control disabled and Start blocked behind it.
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let failure = GuesthouseError.unauthorizedCaller
        let card = EnvironmentCardState(
            environment: environment, status: nil, operation: nil, lastError: failure,
            statusUnread: true, statusCheckFailed: true, statusQueryFailure: failure
        )
        let recovery = card.recovery
        #expect(recovery?.options.contains { $0.action == .inspectState && $0.availability == .enabled } == true)
        #expect(recovery?.options.contains { $0.availability == .enabled } == true, "the card always keeps one control that works")
    }

    @Test func anErrorThatAlreadyWorksDoesNotGrowASecondCheck() {
        // The fallback above is added only when nothing else can be pressed: an error whose own
        // Try again or Check works must not end up with two buttons that do the same thing.
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let failure = GuesthouseError.runtimeStateUnavailable(reason: SanitizedText("inventory unreadable"))
        let card = EnvironmentCardState(
            environment: environment, status: nil, operation: nil, lastError: failure,
            statusUnread: true, statusCheckFailed: true, statusQueryFailure: failure
        )
        let checks = card.recovery?.options.filter { $0.action == .inspectState } ?? []
        #expect(checks.count == 1)
    }

    @Test func recoveryControlsWrapInsteadOfOverflowingTheCard() {
        // Four options at a card's narrow column: the row breaks rather than truncating.
        let widths: [CGFloat] = [120, 150, 110, 130]
        #expect(WrappingRows.rows(of: widths, spacing: 8, in: 300) == [[0, 1], [2, 3]])
        #expect(WrappingRows.rows(of: widths, spacing: 8, in: 1_000) == [[0, 1, 2, 3]])
        // A control wider than the row still gets one of its own rather than being dropped.
        #expect(WrappingRows.rows(of: [400, 50], spacing: 8, in: 100) == [[0], [1]])
        #expect(WrappingRows.rows(of: [], spacing: 8, in: 300).isEmpty)
        // …and it is held to that row's width. The layout reports no more than the width it
        // was offered, so a child given its own intrinsic width would be drawn outside the
        // card — which an enlarged accessibility text size or a longer localized title is
        // enough to produce.
        #expect(WrappingRows.fittedWidths(of: [400, 50], in: 100) == [100, 50])
        #expect(WrappingRows.fittedWidths(of: widths, in: 300) == widths, "a control that fits is left alone")
    }
}
