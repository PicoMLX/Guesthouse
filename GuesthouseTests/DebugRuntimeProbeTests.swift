import GuesthouseCore
import Testing
@testable import Guesthouse

@Suite @MainActor struct DebugRuntimeProbeTests {
    @Test func runtimeResultPreservesBothProviderResults() {
        let description = DebugRuntimeProbe.describe(RuntimeVersionInfo(
            serviceVersion: "1.2.3",
            serviceBuild: "45",
            tart: .init(version: "2.36.0", verified: true),
            lume: .init(version: "0.5.3", verified: true)
        ))

        #expect(description.contains("Tart: 2.36.0 verified"))
        #expect(description.contains("Lume: 0.5.3 verified"))
    }

    @Test func tartResultRetainsVersionAndVerification() {
        #expect(DebugRuntimeProbe.describe(.init(version: "2.36.0", verified: true)) == "2.36.0 verified")
        #expect(DebugRuntimeProbe.describe(.init(version: "2.35.0", verified: false)) == "2.35.0 unverified")
    }

    @Test func missingCapabilitiesAreReportedAsNotChecked() {
        let description = DebugRuntimeProbe.describe(.init(
            version: "0.5.3",
            verified: true,
            problem: .runtimeProbeFailed
        ))

        #expect(description.contains("CLI capabilities: unattended Tahoe not checked, create/run/attach storage not checked, detached run not checked, native attach not checked, VNC disable not checked"))
        #expect(!description.contains("unavailable"))
    }

    @Test func allObservedCapabilitiesAreReportedAvailable() {
        let capabilities = RuntimeVersionInfo.LumeCapabilities(
            unattendedTahoe: true,
            createRunAttachStorage: true,
            detachedRun: true,
            nativeAttach: true,
            vncCanBeDisabled: true
        )
        let description = DebugRuntimeProbe.describe(.init(
            version: "0.5.3",
            verified: true,
            capabilities: capabilities
        ))

        #expect(description == "0.5.3 verified, CLI capabilities: unattended Tahoe available, create/run/attach storage available, detached run available, native attach available, VNC disable available")
    }

    @Test(arguments: [
        (0, "unattended Tahoe"),
        (1, "create/run/attach storage"),
        (2, "detached run"),
        (3, "native attach"),
        (4, "VNC disable")
    ])
    func eachUnavailableCapabilityIsVisible(failedCapability: Int, label: String) {
        let capabilities = RuntimeVersionInfo.LumeCapabilities(
            unattendedTahoe: failedCapability != 0,
            createRunAttachStorage: failedCapability != 1,
            detachedRun: failedCapability != 2,
            nativeAttach: failedCapability != 3,
            vncCanBeDisabled: failedCapability != 4
        )
        let description = DebugRuntimeProbe.describe(.init(
            version: "0.5.3",
            verified: true,
            capabilities: capabilities
        ))

        #expect(description.contains("\(label) unavailable"))
    }

    @Test func lumeProblemsExposeTheirDeclaredRecoveryChoices() {
        let description = DebugRuntimeProbe.describe(.init(
            version: nil,
            verified: false,
            problem: .runtimeMissing
        ))

        #expect(description.contains(GuesthouseError.runtimeMissing.userMessage))
        #expect(description.contains("Declared recovery: Repair runtime; Cancel."))
    }
}
