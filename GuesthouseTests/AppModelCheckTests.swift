import Foundation
import GuesthouseCore
import Observation
import Synchronization
import Testing
@testable import Guesthouse

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppModelCheckTests {
    @Test(arguments: [false, true], [RuntimeSessionFailure.Cause.connectionLost, .malformedResponse,
                                   .oversizedResponse, .protocolMismatch(service: 7)])
    func localQueryFailuresUseAppObservationIDsAndKeepTheirQueryScope(statusQuery: Bool, cause: RuntimeSessionFailure.Cause) async throws {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend), environment = DevelopmentEnvironment(name: "Saved Mac")
        let check = model.checkEnvironments(); var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        if statusQuery {
            backend.answer([.environments(.available([environment]))]); _ = await sent.next()
        }
        let unobserved = OperationID()
        backend.fail(RuntimeSessionFailure(cause: cause, operationID: unobserved)); await check.value
        #expect(model.checkState == .interrupted(cause) && model.statuses.isEmpty)
        let event = try #require(model.sessionDiagnostics.records.first?.event)
        #expect(model.sessionDiagnostics.records.count == 1 && event.origin == .appObservation)
        #expect(event.operationID != unobserved.uuid && event.environmentID == (statusQuery ? environment.id : nil))
        #expect(!model.startMayHaveMutated && model.startDiagnostics.records.isEmpty)
        let text = try #require(DiagnosticsSelection.text(in: model.sessionDiagnostics, matching: "App observation", selection: [0]))
        #expect(text.contains("App observation") && text.contains(event.operationID.uuidString))
        #expect(!text.contains(unobserved.uuid.uuidString) && !text.contains("partial changes may remain"))
        if cause == .malformedResponse || cause == .oversizedResponse {
            #expect(!text.contains("in-flight operation may still be running"))
        }
        let exported = try DiagnosticsExportBuilder.build(log: model.sessionDiagnostics, environmentIDs: [environment.id])
        #expect(String(decoding: try #require(exported.files["log.txt"]), as: UTF8.self).contains(event.message))
    }

    @Test(arguments: [RuntimeSavedStateStatus.loading, .repairRequired, .incompatible, .unavailable])
    func unavailableMetadataIsRetainedWithoutInventingARuntimeOperation(state: RuntimeSavedStateStatus) async throws {
        let backend = FakeRuntimeBackend(); await backend.setEnvironmentInventory(.unavailable(state))
        let model = AppModel(backend: backend); await model.checkEnvironments().value
        let event = try #require(model.sessionDiagnostics.records.first?.event)
        #expect(event.origin == .appObservation && event.environmentID == nil)
        #expect(event.outcome == .observationFailed(.metadataUnavailable(state)))
        #expect(event.message.contains(state.userMessage) && event.recoveryMessage == state.recoveryMessage)
        model.connectionInterrupted(.connectionLost)
        #expect(model.sessionDiagnostics.records.count == 1) // Retirement preserves the specific failure.
        await model.checkEnvironments().value
        #expect(model.sessionDiagnostics.records.count == 2 && model.sessionDiagnostics.records.last?.event.operationID != event.operationID)
    }

    @Test func unknownLocalErrorsCannotReachDiagnosticOutput() async throws {
        struct PrivateError: Error, CustomStringConvertible { var description: String { "synthetic-private-error" } }
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let check = model.checkEnvironments(); var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        backend.fail(PrivateError()); await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
        let event = try #require(model.sessionDiagnostics.records.first?.event)
        #expect(event.origin == .appObservation && event.outcome == .observationFailed(.malformedResponse))
        let exported = try DiagnosticsExportBuilder.build(log: model.sessionDiagnostics)
        #expect(exported.files.values.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("synthetic-private-error") })
    }

    @Test(arguments: [false, true])
    func localErrorsCannotSupplyUnobservedOperationOrForeignEnvironmentIDs(operationID: Bool) async throws {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend), foreign = EnvironmentID(), unobserved = OperationID()
        let check = model.checkEnvironments(); var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        backend.fail(operationID ? GuesthouseError.operationOutcomeUnknown(unobserved) : .hostKeyChanged(foreign))
        await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
        #expect(model.sessionDiagnostics.records.first?.event.origin == .appObservation)
        let text = model.sessionDiagnostics.text
        #expect(!text.contains(foreign.description) && !text.contains(unobserved.uuid.uuidString))
    }
    @Test func checksSavedRecordsWithoutUpgradingUncertainStatusToReady() async {
        let backend = FakeRuntimeBackend(), environment = DevelopmentEnvironment(name: "Development Mac")
        let status = EnvironmentStatus(environmentID: environment.id,
            vm: .uncertain(reason: .ownershipUnproven), readiness: .checking)
        await backend.setEnvironmentInventory(.available([environment]))
        await backend.setStatus(status)
        let model = AppModel(backend: backend)
        #expect(model.checkState == .checkingEnvironment)
        await model.checkEnvironments().value
        #expect(model.checkState == .checked)
        #expect(model.environments == [environment] && model.statuses == [environment.id: status])
        #expect(await backend.receivedRequests == [.listEnvironments, .environmentStatus(environment.id)])
    }

    @Test(arguments: [RuntimeSavedStateStatus.loading, .repairRequired, .incompatible, .unavailable])
    func unavailableInventoryIsNeverAnEmptySuccessfulCheck(state: RuntimeSavedStateStatus) async {
        let backend = FakeRuntimeBackend()
        await backend.setEnvironmentInventory(.unavailable(state))
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        #expect(model.checkState == .metadataUnavailable(state) && model.statuses.isEmpty)
        #expect(await backend.receivedRequests == [.listEnvironments])
        model.connectionInterrupted(.connectionLost)
        #expect(model.checkState == .metadataUnavailable(state))
    }

    @Test func idleConnectionLossClearsStatusAndDoesNotRetry() async {
        let backend = FakeRuntimeBackend(), environment = DevelopmentEnvironment(name: "Saved Mac")
        await backend.setEnvironmentInventory(.available([environment]))
        await backend.setStatus(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        withObservationTracking { _ = model.checkState } onChange: { changed.yield(()) }
        await backend.simulateConnectionInterruption()
        var iterator = changes.makeAsyncIterator()
        _ = await iterator.next()
        #expect(model.checkState == .interrupted(.connectionLost))
        #expect(model.statuses.isEmpty && model.environments == [environment])
        #expect(await backend.receivedRequests.count == 2)
        await model.checkEnvironments().value
        #expect(model.checkState == .checked && model.statuses.count == 1)
    }

    @Test func repeatedChecksJoinAndLateSuccessAfterLossCannotPublish() async {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let first = model.checkEnvironments(), joined = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator()
        _ = await sent.next()
        #expect(backend.requests == [.listEnvironments] && model.isChecking)
        model.connectionInterrupted(.connectionLost)
        backend.answer([.environments(.available([DevelopmentEnvironment(name: "Late saved Mac")]))])
        await first.value
        await joined.value
        #expect(model.checkState == .interrupted(.connectionLost) && !model.isChecking)
        #expect(model.statuses.isEmpty && backend.requests.count == 1)
    }

    @Test(arguments: [[], [.completed(OperationID())],
                     [.environments(.available([])), .environments(.available([]))],
                     [.environments(.unavailable(.loaded))]] as [[RuntimeEvent]])
    func malformedInventoryDoesNotPublishSuccess(events: [RuntimeEvent]) async {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let check = model.checkEnvironments()
        var sent = backend.sent.makeAsyncIterator()
        _ = await sent.next()
        backend.answer(events)
        await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
    }

    @Test func foreignStatusAndPartialResultsAreNotPublished() async {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let check = model.checkEnvironments(), environment = DevelopmentEnvironment(name: "Saved Mac")
        let second = DevelopmentEnvironment(name: "Another Mac")
        var sent = backend.sent.makeAsyncIterator()
        _ = await sent.next()
        backend.answer([.environments(.available([environment, second]))])
        _ = await sent.next()
        backend.answer([.status(.init(environmentID: environment.id, vm: .stopped, readiness: .checking))])
        _ = await sent.next()
        backend.answer([.status(.init(environmentID: EnvironmentID(), vm: .running, readiness: .ready))])
        await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
        #expect(model.environments.isEmpty && model.statuses.isEmpty)
    }

    @Test func cancellationBeforeTheCheckStartsSendsNothingAndAllowsAnotherCheck() async {
        let backend = FakeRuntimeBackend()
        let checkedModel = AppModel(backend: backend)
        let task = checkedModel.checkEnvironments()
        task.cancel()
        await task.value
        #expect(checkedModel.checkState == .unavailable(.canceled) && !checkedModel.isChecking)
        #expect(await backend.receivedRequests.isEmpty)
        await checkedModel.checkEnvironments().value
        #expect(checkedModel.checkState == .checked)
    }

    @Test func failedCheckDoesNotStartAnAutomaticReconnectLoop() async {
        let backend = FakeRuntimeBackend()
        let checkedModel = AppModel(backend: backend)
        await backend.script("listEnvironments", .disconnect())
        await checkedModel.checkEnvironments().value
        #expect(checkedModel.checkState == .interrupted(.connectionLost))
        #expect(await backend.receivedRequests == [.listEnvironments])
    }

    @Test func typedFailureKeepsRecoveryAndDoesNotRetryOnFollowingRetirement() async {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .fail(error: .unauthorizedCaller))
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        model.connectionInterrupted(.connectionLost)
        #expect(model.checkState == .unavailable(.unauthorizedCaller))
        #expect(await backend.receivedRequests == [.listEnvironments])
    }

    @Test(arguments: [false, true], [false, true])
    func terminalQueryFailuresRetainActualIDsAndRejectForeignTargets(statusQuery: Bool, foreign: Bool) async throws {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend), operation = OperationID()
        let environment = DevelopmentEnvironment(name: "Saved Mac")
        let check = model.checkEnvironments(); var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        if statusQuery {
            backend.answer([.environments(.available([environment]))]); _ = await sent.next()
        }
        let error: GuesthouseError = foreign ? .hostKeyChanged(EnvironmentID())
            : statusQuery ? .guestNotReachable(environment.id) : .runtimeMissing
        backend.answer([.failed(operation, error)]); await check.value
        #expect(model.checkState == .unavailable(foreign ? .invalidRuntimeReply(.malformed) : error))
        #expect(backend.requests.count == (statusQuery ? 2 : 1) && model.statuses.isEmpty)
        let expected = DiagnosticEvent(operation: .inspectEnvironment, outcome: .operationFailed(error),
            operationID: operation.uuid, environmentID: statusQuery ? environment.id : nil)
        if foreign {
            #expect(model.sessionDiagnostics.records.count == 1)
            #expect(model.sessionDiagnostics.records.first?.event.origin == .appObservation)
            #expect(model.sessionDiagnostics.records.first?.event.outcome == .observationFailed(.malformedResponse))
            #expect(!model.sessionDiagnostics.text.contains(operation.uuid.uuidString))
        } else { #expect(model.sessionDiagnostics.records.map(\.event) == [expected]) }
        if !foreign {
            let export = try DiagnosticsExportBuilder.build(log: model.sessionDiagnostics)
            let text = String(decoding: try #require(export.files["log.txt"]), as: UTF8.self)
            #expect(text.contains(operation.uuid.uuidString) && text.contains(error.userMessage) && text.contains(error.recoveryMessage))
        }
    }

    @Test func aRetiredQueryCannotPublishFailureDiagnosticsAsTheCurrentCheck() async {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let check = model.checkEnvironments(); var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        model.connectionInterrupted(.connectionLost)
        backend.answer([.failed(OperationID(), .runtimeMissing)]); await check.value
        #expect(model.checkState == .interrupted(.connectionLost) && model.sessionDiagnostics.records.count == 1)
        #expect(model.sessionDiagnostics.records.first?.event.origin == .appObservation)
        #expect(model.sessionDiagnostics.records.first?.event.outcome == .observationFailed(.connectionLost))
    }

    @Test func connectionRetirementBeforeTheStreamFailureKeepsTheActiveQueryTarget() async throws {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let environment = DevelopmentEnvironment(name: "Saved Mac"), other = DevelopmentEnvironment(name: "Other Mac")
        let check = model.checkEnvironments(); var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        backend.answer([.environments(.available([environment, other]))]); _ = await sent.next()
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changed.finish() }
        withObservationTracking { _ = model.checkState } onChange: { changed.yield(()) }
        backend.interrupt(.connectionLost)
        var observed = changes.makeAsyncIterator(); _ = await observed.next()
        // Production retires the generation before cancellation delivers the stream failure.
        backend.fail(RuntimeSessionFailure(cause: .connectionLost)); await check.value
        #expect(model.checkState == .interrupted(.connectionLost) && backend.requests.count == 2)
        let event = try #require(model.sessionDiagnostics.records.first?.event)
        #expect(model.sessionDiagnostics.records.count == 1 && event.origin == .appObservation)
        #expect(event.environmentID == environment.id && event.outcome == .observationFailed(.connectionLost))
        #expect(model.sessionDiagnostics.selecting(environments: [other.id]).records.isEmpty)
        let export = try DiagnosticsExportBuilder.build(log: model.sessionDiagnostics, environmentIDs: [other.id])
        #expect(!String(decoding: try #require(export.files["log.txt"]), as: UTF8.self).contains(event.operationID.uuidString))
    }

    @Test func aFailureFollowingAPayloadIsMalformedAndDoesNotRetainTheClaimedError() async {
        let backend = HeldCheckBackend(), model = AppModel(backend: backend)
        let check = model.checkEnvironments(); var sent = backend.sent.makeAsyncIterator(); _ = await sent.next()
        backend.answer([.environments(.available([])), .failed(OperationID(), .runtimeMissing)]); await check.value
        #expect(model.checkState == .unavailable(.invalidRuntimeReply(.malformed)))
        #expect(model.sessionDiagnostics.records.count == 1)
        #expect(model.sessionDiagnostics.records.first?.event.origin == .appObservation)
        #expect(model.sessionDiagnostics.records.first?.event.outcome == .observationFailed(.malformedResponse))
    }
}

/// Controlled asynchronous replies without timing-based waits or native service access.
private nonisolated final class HeldCheckBackend: RuntimeBackend {
    struct State {
        var requests: [RuntimeRequest] = []
        var reply: AsyncThrowingStream<RuntimeEvent, any Error>.Continuation?
    }
    private let state = Mutex(State())
    let connectionInterruptions: AsyncStream<RuntimeSessionFailure.Cause>
    private let interruptionSink: AsyncStream<RuntimeSessionFailure.Cause>.Continuation
    let sent: AsyncStream<Void>
    private let sendSignal: AsyncStream<Void>.Continuation
    var requests: [RuntimeRequest] { state.withLock { $0.requests } }
    init() {
        (connectionInterruptions, interruptionSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (sent, sendSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    deinit { interruptionSink.finish(); sendSignal.finish() }
    func send(_ request: RuntimeRequest) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        let (stream, reply) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        state.withLock { $0.requests.append(request); $0.reply = reply }
        sendSignal.yield(())
        return stream
    }
    func answer(_ events: [RuntimeEvent]) {
        let reply = state.withLock { state in defer { state.reply = nil }; return state.reply }
        for event in events { reply?.yield(event) }
        reply?.finish()
    }
    func fail(_ error: any Error) {
        let reply = state.withLock { state in defer { state.reply = nil }; return state.reply }
        reply?.finish(throwing: error)
    }
    func interrupt(_ cause: RuntimeSessionFailure.Cause) { interruptionSink.yield(cause) }
}
