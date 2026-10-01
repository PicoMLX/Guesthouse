import AppKit
import GuesthouseClientKit
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor struct AppScenesTests {
    @Test func earlyQuitIsPresentedOnBindingAndClosingTheWindowDoesNotTerminate() {
        let delegate = AppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        let quit = QuitCoordinator(model: AppModel(backend: FakeRuntimeBackend())) { _ in }
        delegate.coordinator = quit
        #expect(quit.flow == .confirming)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        quit.cancelQuit()
    }

    @Test func simulatedBackendRequiresAnExplicitDevelopmentEnvironment() {
        #expect(AppRuntimeConfiguration.makeBackend(environment: [:]) is RuntimeClient)
        #if DEBUG
        #expect(AppRuntimeConfiguration.makeBackend(environment: ["GUESTHOUSE_FAKE_RUNTIME": "1"]) is FakeRuntimeBackend)
        #expect(AppRuntimeConfiguration.makeBackend(environment: ["XCTestConfigurationFilePath": "fixture"]) is FakeRuntimeBackend)
        #else
        #expect(AppRuntimeConfiguration.makeBackend(environment: ["GUESTHOUSE_FAKE_RUNTIME": "1"]) is RuntimeClient)
        #endif
    }

    @Test func uncertaintyNeverBecomesNoRunningMacsAndRepairRetainsItsGuidance() async {
        let backend = FakeRuntimeBackend(), environment = DevelopmentEnvironment(name: "Saved Mac")
        await backend.setEnvironmentInventory(.available([environment]))
        await backend.setStatus(.init(environmentID: environment.id, vm: .uncertain(reason: .ownershipUnproven), readiness: .checking))
        let model = AppModel(backend: backend)
        await model.checkEnvironments().value
        #expect(model.environmentSummary == "Development Mac state needs inspection")
        let failure = QuitCoordinator.Failure.stop(.runtimeIncompatible)
        #expect(!failure.userMessage.isEmpty && !failure.recoveryMessage.isEmpty && !failure.canInspect)
        #expect(!QuitCoordinator.Failure.check(.metadataUnavailable(.repairRequired)).canInspect)
    }
}
