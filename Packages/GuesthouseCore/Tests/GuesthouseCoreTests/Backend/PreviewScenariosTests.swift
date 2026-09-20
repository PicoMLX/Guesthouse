import Foundation
import Testing
@testable import GuesthouseCore

/// Retained #60 preview assertions against the current snapshot/provisioning models.
/// These factories simulate UI states; passing tests would not prove a real VM or provider.
@Suite(.timeLimit(.minutes(1))) struct PreviewScenariosTests {
    @Test(arguments: 0..<5)
    func catalogScenariosHaveConsistentSnapshotsAndMatchingFakeStatuses(index: Int) async throws {
        try #require(PreviewScenarios.all.count == 5)
        let scenario = await PreviewScenarios.all[index]()
        let names = ["Fresh Mac", "One running environment", "Environment needing repair", "Both slots full", "Operation in progress"]
        let counts = [0, 1, 1, 2, 1]
        #expect(scenario.name == names[index])
        #expect(scenario.snapshot.environments.count == counts[index])
        #expect(scenario.snapshot.slots.occupiedSlots == counts[index])
        #expect(await scenario.backend.receivedRequests.isEmpty)
        try scenario.snapshot.validate()
        let data = try JSONEncoder().encode(scenario.snapshot)
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: data) == scenario.snapshot)
        // Keep the preview's visual delay; bypass elapsed time only in this test instance.
        await scenario.backend.setEventPause {}
        for environment in scenario.snapshot.environments {
            let expected = try #require(await scenario.backend.status(of: environment.id))
            #expect(try await collect(scenario.backend.send(.environmentStatus(environment.id))) == [.status(expected)])
            #expect(expected.vm != .notFound)
            #expect(expected.observed.runtimeProvider == nil)
            #expect(expected.observed.runtimeVersion == nil)
        }
        #expect(try await collect(scenario.backend.send(.runtimeVersion)) ==
                [.runtimeVersion(RuntimeVersionInfo(serviceVersion: "0.0.0", serviceBuild: "fake"))])
    }

    @Test func freshMacStartsWithNoEnvironmentOrInitialOperation() async throws {
        let scenario = await PreviewScenarios.freshMac()
        #expect(scenario.snapshot == .empty)
        #expect(scenario.initialRequest == nil)
        #expect(await scenario.backend.receivedRequests.isEmpty)
    }

    @Test func runningEnvironmentCanBeStoppedByItsScriptedBackend() async throws {
        let scenario = await PreviewScenarios.oneRunningEnvironment()
        let environment = try #require(scenario.snapshot.environments.first)
        #expect(scenario.initialRequest == nil)
        #expect(await scenario.backend.status(of: environment.id)?.vm == .running)
        let events = try await collect(scenario.backend.send(.stopEnvironment(environment.id, .graceful(deadline: .seconds(30)))))
        #expect(events.map(\.caseName) == ["accepted", "progress", "status", "completed"])
        #expect(await scenario.backend.status(of: environment.id)?.vm == .stopped)
        #expect(await scenario.backend.status(of: environment.id)?.inFlightOperation == nil)
    }

    @Test func preservedEnvironmentStillOccupiesTheSecondSlot() async throws {
        let scenario = await PreviewScenarios.bothSlotsFull()
        try #require(scenario.snapshot.environments.count == 2)
        let active = scenario.snapshot.environments[0], preserved = scenario.snapshot.environments[1]
        #expect(scenario.snapshot.slots.isFull)
        #expect(scenario.snapshot.slots.availableSlots == 0)
        #expect(scenario.snapshot.slots.state(of: active.id) == .active)
        #expect(scenario.snapshot.slots.state(of: preserved.id) == .preserved)
        #expect(await scenario.backend.status(of: preserved.id)?.readiness == .needsAttention(.guestNotReachable(preserved.id)))
        var slots = scenario.snapshot.slots
        #expect(throws: VMSlotError.inventoryFull(maximum: 2)) { try slots.reserve(EnvironmentID()) }
    }

    @Test func progressPreviewStartsWithItsSeededIdentityAndFinishesRunning() async throws {
        let scenario = await PreviewScenarios.operationInProgress()
        let environment = try #require(scenario.snapshot.environments.first)
        let id = try #require(await scenario.backend.status(of: environment.id)?.inFlightOperation)
        let request = try #require(scenario.initialRequest)
        #expect(request == .startEnvironment(environment.id, StartOptions()))
        await scenario.backend.setEventPause {}
        let events = try await collect(scenario.backend.send(request))
        try #require(events.count == 7)
        #expect(Array(events.prefix(5)) == [
            .accepted(id), .progress(id, ProgressPhase(kind: .verifyingRuntime)),
            .progress(id, ProgressPhase(kind: .startingVM)),
            .progress(id, ProgressPhase(kind: .waitingForNetwork, fraction: 0.3)),
            .progress(id, ProgressPhase(kind: .waitingForNetwork, fraction: 0.9))
        ])
        guard case .status(let status) = events[5] else {
            Issue.record("Expected the scripted running status."); return
        }
        #expect(status.inFlightOperation == id)
        #expect(events[6] == .completed(id))
        #expect(await scenario.backend.status(of: environment.id)?.vm == .running)
        #expect(await scenario.backend.status(of: environment.id)?.inFlightOperation == nil)
    }

    @Test func repairPreviewRetainsTheTypedHostKeyFailure() async throws {
        let scenario = await PreviewScenarios.environmentNeedingRepair()
        let environment = try #require(scenario.snapshot.environments.first)
        #expect(scenario.snapshot.provisioning[environment.id] == ProvisioningState(
            stage: .sshPaired, status: .recoverableFailure(.hostKeyChanged(environment.id), interrupted: nil)
        ))
        #expect(await scenario.backend.status(of: environment.id)?.readiness == .needsAttention(.hostKeyChanged(environment.id)))
        let id = OperationID()
        await scenario.backend.useOperationID(id, forNext: "startEnvironment")
        #expect(try await collect(scenario.backend.send(.startEnvironment(environment.id, StartOptions()))) ==
                [.accepted(id), .failed(id, .hostKeyChanged(environment.id))])
    }

    @Test func factoryCallsDoNotShareMutableBackendOrEnvironmentIdentity() async throws {
        let first = await PreviewScenarios.oneRunningEnvironment()
        let second = await PreviewScenarios.oneRunningEnvironment()
        let firstID = try #require(first.snapshot.environments.first?.id)
        let secondID = try #require(second.snapshot.environments.first?.id)
        #expect(firstID != secondID)
        #expect(first.backend !== second.backend)
        _ = try await collect(first.backend.send(.stopEnvironment(firstID, .force)))
        #expect(await first.backend.status(of: firstID)?.vm == .stopped)
        #expect(await second.backend.status(of: secondID)?.vm == .running)
        #expect(await second.backend.receivedRequests.isEmpty)
    }

    private func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
