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
        #expect(events[3] == .status(status))
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
        let repair = await PreviewScenarios.environmentNeedingRepair()
        let id = repair.snapshot.environments[0].id
        let events = try await collect(repair.backend.send(.startEnvironment(id, StartOptions())))
        #expect(events.last?.caseName == "failed")
    }
}
