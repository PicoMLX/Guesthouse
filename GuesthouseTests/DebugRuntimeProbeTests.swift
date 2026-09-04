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

        #expect(description.contains("VNC disable not checked"))
        #expect(!description.contains("VNC disable unavailable"))
    }

    @Test func observedVNCResultStillDistinguishesFalseFromTrue() {
        let unavailable = RuntimeVersionInfo.LumeCapabilities(
            unattendedTahoe: true,
            createRunAttachStorage: true,
            detachedRun: true,
            nativeAttach: true,
            vncCanBeDisabled: false
        )
        let available = RuntimeVersionInfo.LumeCapabilities(
            unattendedTahoe: true,
            createRunAttachStorage: true,
            detachedRun: true,
            nativeAttach: true,
            vncCanBeDisabled: true
        )

        #expect(DebugRuntimeProbe.describe(.init(
            version: "0.5.3",
            verified: true,
            capabilities: unavailable
        )).contains("VNC disable unavailable"))
        #expect(DebugRuntimeProbe.describe(.init(
            version: "0.5.3",
            verified: true,
            capabilities: available
        )).contains("VNC disable available"))
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
