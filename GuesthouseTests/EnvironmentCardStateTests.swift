import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor struct EnvironmentCardStateTests {
    @Test(arguments: Array(PreviewScenarios.all.indices))
    func catalogScenariosKeepActionsExplicitAndCapabilitiesIndependent(index: Int) async {
        let scenario = await PreviewScenarios.all[index]()
        await scenario.backend.setEnvironmentInventory(.available(scenario.snapshot.environments))
        let model = AppModel(backend: scenario.backend)
        await model.checkEnvironments().value
        #expect(model.checkState == .checked)
        #expect(model.environments.count <= 2)
        for environment in model.environments {
            let state = EnvironmentCardState(environment: environment, status: model.statuses[environment.id], checked: true, busy: false)
            #expect(state.id == environment.id)
            #expect(EnvironmentCardState.Action.allCases.allSatisfy { !state.reason(for: $0).isEmpty })
            #expect(state.details.first { $0.label == "Disk usage" }?.value == "Not measured")
            #expect(state.details.first { $0.label == "Accounts" }?.value == "Not checked")
            #expect(!EnvironmentCardState.Action.delete.primary)
            #expect(!state.statusText.contains("Ready"))
        }
    }

    @Test(arguments: [false, true])
    func staleOrForeignStatusCannotPublishToolValues(foreign: Bool) {
        let environment = DevelopmentEnvironment(name: "Dev Mac", guestDiskBytes: .max)
        let status = EnvironmentStatus(environmentID: foreign ? EnvironmentID() : environment.id, vm: .running,
            readiness: .ready, observed: ObservedTuple(xcodeBuild: "17F113"))
        let state = EnvironmentCardState(environment: environment, status: status, checked: foreign, busy: false)
        #expect(state.statusText == "Current state unknown")
        #expect(state.details.first { $0.label == "Xcode build" }?.value == "Unknown")
        #expect(state.details.first?.value == UInt64.max.formatted() + " bytes")
        #expect(state.reason(for: .start) == "Check the environment before starting.")
    }

    @Test func uncertainAndFailedStatesExplainRecoveryWithoutPretendingToCheckForever() {
        let environment = DevelopmentEnvironment(name: "Dev Mac")
        let uncertain = EnvironmentCardState(environment: environment, status: .init(environmentID: environment.id,
            vm: .uncertain(reason: .ownershipUnproven), readiness: .ready), checked: true, busy: false)
        #expect(uncertain.statusText == "State needs inspection")
        #expect(uncertain.guidance?.contains("Inspect") == true)
        let error = GuesthouseError.hostKeyChanged(environment.id)
        let stopped = EnvironmentCardState(environment: environment, status: .init(environmentID: environment.id,
            vm: .stopped, readiness: .needsAttention(error)), checked: true, busy: false)
        #expect(stopped.statusText == "Stopped")
        #expect(stopped.guidance?.contains(error.recoveryMessage) == true)
        #expect(stopped.reason(for: .start) == error.recoveryMessage)
    }
}
