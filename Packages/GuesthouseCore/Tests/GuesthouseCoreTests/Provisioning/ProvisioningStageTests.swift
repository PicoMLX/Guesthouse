import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProvisioningStageTests {
    @Test func stagesFollowThePlanOrder() {
        #expect(ProvisioningStage.allCases.map(\.rawValue) == [
            "preflight", "runtimeReady", "macOSInstalled", "needsGuestSetup", "sshPaired",
            "guestSecured", "xcodeToolsReady", "accountsReady", "workspaceValidated", "ready",
        ])
        #expect(ProvisioningStage.first == .preflight)
        #expect(ProvisioningStage.preflight.next == .runtimeReady)
        #expect(ProvisioningStage.ready.next == nil)
        #expect(ProvisioningStage.preflight < ProvisioningStage.ready)
    }
}
