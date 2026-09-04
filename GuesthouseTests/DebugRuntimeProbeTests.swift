import GuesthouseCore
import Testing
@testable import Guesthouse

@Suite @MainActor struct DebugRuntimeProbeTests {
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
}
