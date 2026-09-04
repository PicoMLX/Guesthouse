import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct FakeRuntimeBackendTests {
    let environment = EnvironmentID()

    func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func successScenarioEmitsStagedProgressThenCompleted() async throws {
        let backend = FakeRuntimeBackend()
        let phases = [ProgressPhase(kind: .startingVM), ProgressPhase(kind: .waitingForNetwork, fraction: 0.5)]
        let status = EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready)
        await backend.script("startEnvironment", .succeed(phases: phases, status: status))

        let events = try await collect(backend.send(.startEnvironment(environment, StartOptions())))
        #expect(events.map(\.caseName) == ["accepted", "progress", "progress", "status", "completed"])
        guard case .accepted(let id) = events[0] else { Issue.record("no accepted"); return }
        #expect(events[1] == .progress(id, phases[0]))
        var inFlight = status
        inFlight.inFlightOperation = id
        #expect(events[3] == .status(inFlight), "the emitted status names the operation that has not completed yet")
        #expect(events[4] == .completed(id))
        #expect(await backend.status(of: environment) == status)
        #expect(await backend.receivedRequests == [.startEnvironment(environment, StartOptions())])
    }

    @Test func failureScenarioEndsWithTheGivenError() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("stopEnvironment", .fail(after: [ProgressPhase(kind: .stoppingVM)], error: .guestNotReachable(environment)))
        let events = try await collect(backend.send(.stopEnvironment(environment, .force)))
        #expect(events.map(\.caseName) == ["accepted", "progress", "failed"])
        guard case .failed(_, let error) = events.last! else { Issue.record("no failed"); return }
        #expect(error == .guestNotReachable(environment))
    }

    @Test func disconnectScenarioThrowsInterruptionSoOutcomeIsUnknown() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("importXcode", .disconnect(after: [ProgressPhase(kind: .copying)]))
        let handoff = FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app")
        var seen: [String] = []
        await #expect(throws: RuntimeConnectionInterrupted.self) {
            for try await event in backend.send(.importXcode(environment, handoff)) {
                seen.append(event.caseName)
            }
        }
        #expect(seen == ["accepted", "progress"])
    }

    @Test func cancellingTheConsumerStopsAHangingOperationAndRecordsCancel() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("startEnvironment", .hang)
        let stream = backend.send(.startEnvironment(environment, StartOptions()))
        let consumer = Task {
            var events: [RuntimeEvent] = []
            do {
                for try await event in stream { events.append(event) }
            } catch {}
            return events
        }
        while await backend.receivedRequests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        consumer.cancel()
        _ = await consumer.value
        for _ in 0..<200 where await backend.receivedRequests.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await backend.receivedRequests
        #expect(requests.count == 2)
        guard case .cancelOperation = requests[1] else { Issue.record("no cancelOperation recorded: \(requests)"); return }
    }

    @Test func cancelOperationRequestEndsAHangingOperation() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("startEnvironment", .hang)
        let stream = backend.send(.startEnvironment(environment, StartOptions()))
        var iterator = stream.makeAsyncIterator()
        guard case .accepted(let id) = try await iterator.next() else { Issue.record("no accepted"); return }
        _ = try await collect(backend.send(.cancelOperation(id)))
        let last = try await iterator.next()
        #expect(last == .failed(id, .canceled))
        #expect(try await iterator.next() == nil)
        #expect(await backend.receivedRequests == [.startEnvironment(environment, StartOptions()), .cancelOperation(id)])
    }

    @Test func cancelRequestsHonorScenarios() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("startEnvironment", .hang)
        await backend.script("cancelOperation", .disconnect())
        let stream = backend.send(.startEnvironment(environment, StartOptions()))
        var iterator = stream.makeAsyncIterator()
        guard case .accepted(let id) = try await iterator.next() else { Issue.record("no accepted"); return }
        await #expect(throws: RuntimeConnectionInterrupted.self) {
            for try await _ in backend.send(.cancelOperation(id)) {}
        }
        await backend.script("cancelOperation", .fail(error: .unauthorizedCaller))
        let events = try await collect(backend.send(.cancelOperation(id)))
        #expect(events == [.failed(id, .unauthorizedCaller)])
        #expect(await backend.receivedRequests.count == 3)
    }

    @Test func seededOperationIDIsReusedByTheNextRequest() async throws {
        let backend = FakeRuntimeBackend()
        let id = OperationID()
        await backend.useOperationID(id, forNext: "startEnvironment")
        let events = try await collect(backend.send(.startEnvironment(environment, StartOptions())))
        #expect(events.first == .accepted(id))
        let again = try await collect(backend.send(.startEnvironment(environment, StartOptions())))
        #expect(again.first != .accepted(id), "the seeded id is used once")
    }

    @Test func scriptedFailuresApplyToQueries() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("environmentStatus", .disconnect())
        await #expect(throws: RuntimeConnectionInterrupted.self) {
            for try await _ in backend.send(.environmentStatus(environment)) {}
        }
        await backend.script("runtimeVersion", .fail(error: .unauthorizedCaller))
        let events = try await collect(backend.send(.runtimeVersion))
        guard case .failed(_, let error) = events.first! else { Issue.record("expected failed"); return }
        #expect(error == .unauthorizedCaller)
    }

    @Test func requestsAreRecordedInSendOrder() async throws {
        let backend = FakeRuntimeBackend()
        var streams: [AsyncThrowingStream<RuntimeEvent, any Error>] = []
        let requests: [RuntimeRequest] = (0..<20).map { $0.isMultiple(of: 2) ? .startEnvironment(environment, StartOptions()) : .stopEnvironment(environment, .force) }
        for request in requests { streams.append(backend.send(request)) }
        for stream in streams { _ = try await collect(stream) }
        #expect(await backend.receivedRequests == requests)
    }

    @Test func interruptionCarriesRecoveryGuidance() {
        let error = RuntimeConnectionInterrupted(operationID: OperationID())
        #expect(error.recoveryActions.first == .inspectState)
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.guesthouseError?.caseName == "operationOutcomeUnknown")
        #expect(RuntimeConnectionInterrupted().guesthouseError == nil)
    }

    @Test func aQueryInterruptionOffersRetryRatherThanAnUnknownOutcome() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("runtimeVersion", .disconnect())
        do {
            for try await _ in backend.send(.runtimeVersion) {}
            Issue.record("expected an interruption")
        } catch let error as RuntimeConnectionInterrupted {
            #expect(error.operationID == nil)
            #expect(error.recoveryActions == [.retry], "a read-only query has nothing to inspect or cancel")
            #expect(!error.userMessage.contains("may or may not"))
            #expect(error.recoveryMessage.isEmpty == false)
        }
        #expect(RuntimeConnectionInterrupted(operationID: OperationID()).recoveryActions == [.inspectState, .cancel])
    }

    @Test func queriesReplyWithoutOperationIDs() async throws {
        let backend = FakeRuntimeBackend()
        let status = EnvironmentStatus(environmentID: environment, vm: .stopped, readiness: .ready)
        await backend.setStatus(status)
        #expect(try await collect(backend.send(.environmentStatus(environment))) == [.status(status)])
        let unknown = EnvironmentID()
        #expect(try await collect(backend.send(.environmentStatus(unknown))) == [.status(EnvironmentStatus(environmentID: unknown, vm: .notFound, readiness: .checking))])
        let version = try await collect(backend.send(.runtimeVersion))
        guard case .runtimeVersion(let info) = version.first! else { Issue.record("no version"); return }
        #expect(info.tart?.verified == true)
        #expect(await backend.receivedRequests.count == 3)
    }

    @Test func defaultScenarioSucceedsWithoutPhases() async throws {
        let backend = FakeRuntimeBackend()
        let events = try await collect(backend.send(.stopEnvironment(environment, .graceful(deadline: .seconds(30)))))
        #expect(events.map(\.caseName) == ["accepted", "completed"])
    }

    @Test func previewScenariosBuildWithoutIOAndAnswerStatusQueries() async throws {
        for make in PreviewScenarios.all {
            let scenario = await make()
            #expect(!scenario.name.isEmpty)
            for environment in scenario.snapshot.environments {
                let events = try await collect(scenario.backend.send(.environmentStatus(environment.id)))
                guard case .status(let status) = events.first! else { Issue.record("\(scenario.name): no status"); continue }
                #expect(status.environmentID == environment.id, Comment(rawValue: scenario.name))
                #expect(status.vm != .notFound, Comment(rawValue: scenario.name))
            }
            #expect(scenario.snapshot.slots.occupiedSlots == scenario.snapshot.environments.count, Comment(rawValue: scenario.name))
        }
        let full = await PreviewScenarios.bothSlotsFull()
        #expect(full.snapshot.slots.isFull)
        let running = await PreviewScenarios.oneRunningEnvironment()
        let runningID = running.snapshot.environments[0].id
        _ = try await collect(running.backend.send(.stopEnvironment(runningID, .graceful(deadline: .seconds(30)))))
        #expect(await running.backend.status(of: runningID)?.vm == .stopped)
        let inProgress = await PreviewScenarios.operationInProgress()
        let progressID = inProgress.snapshot.environments[0].id
        let seeded = try #require(await inProgress.backend.status(of: progressID)?.inFlightOperation)
        #expect(inProgress.initialRequest == .startEnvironment(progressID, StartOptions()))
        let first = try await inProgress.backend.send(inProgress.initialRequest!).first { _ in true }
        #expect(first == .accepted(seeded), "preview progress events carry the seeded operation id")
        let repair = await PreviewScenarios.environmentNeedingRepair()
        let id = repair.snapshot.environments[0].id
        let events = try await collect(repair.backend.send(.startEnvironment(id, StartOptions())))
        #expect(events.last?.caseName == "failed")
    }
}
