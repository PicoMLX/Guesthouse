import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

private struct OpaqueDiscoveryError: Error, CustomStringConvertible {
    let description: String
}

@Suite struct LumeDiscoveryReportTests {
    @Test func discoveryLogDiagnosticsNeverInspectOpaqueAssociatedValues() {
        let secret = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let diagnostic = LumeDiscoveryReport.redactedDiagnostic(
            for: OpaqueDiscoveryError(description: "/Users/developer/project \(secret): private detail")
        )

        #expect(diagnostic.value == "OpaqueDiscoveryError")
        #expect(!diagnostic.value.contains("/Users/developer/project"))
        #expect(!diagnostic.value.contains(secret))
    }

    @Test func fixedStatesDistinguishCheckingStorageAndMissingRuntime() {
        #expect(LumeDiscoveryReport.checking == .init(version: nil, verified: false))
        #expect(LumeDiscoveryReport.storageUnavailable == .init(
            version: nil,
            verified: false,
            problem: .runtimeStorageUnavailable
        ))
        #expect(LumeDiscoveryReport.missing == .init(
            version: nil,
            verified: false,
            problem: .runtimeMissing
        ))
    }

    @Test func rejectedBundleNeverRetainsVerification() {
        let mismatch = LumeDiscoveryReport.rejectedBundle(.versionMismatch(found: "0.5.2"))
        #expect(mismatch == .init(
            version: "0.5.2",
            verified: false,
            problem: .runtimeIncompatible(found: "0.5.2", required: "0.5.3")
        ))
        #expect(LumeDiscoveryReport.rejectedBundle(.executableDigestMismatch) == .init(
            version: nil,
            verified: false,
            problem: .runtimeProbeFailed
        ))
    }

    @Test func probeFailurePreservesVerificationUnlessRuntimeTrustWasInvalidated() {
        #expect(LumeDiscoveryReport.failedProbe(LumeInvocationError.timedOut, claimedVersion: LumePin.version) == .init(
            version: "0.5.3",
            verified: true,
            problem: .runtimeProbeFailed
        ))
        #expect(LumeDiscoveryReport.failedProbe(LumeInvocationError.bundleChanged, claimedVersion: LumePin.version) == .init(
            version: "0.5.3",
            verified: false,
            problem: .runtimeProbeFailed
        ))
        #expect(LumeDiscoveryReport.failedProbe(LumeInvocationError.storageMismatch, claimedVersion: LumePin.version) == .init(
            version: "0.5.3",
            verified: false,
            problem: .runtimeProbeFailed
        ))
        #expect(LumeDiscoveryReport.failedProbe(
            RuntimeStorageError.insecureDirectory(path: "/private/runtime", reason: "symbolic link"),
            claimedVersion: LumePin.version
        ) == .init(
            version: "0.5.3",
            verified: false,
            problem: .runtimeProbeFailed
        ))
        let mismatched = LumeDiscoveryReport.failedProbe(
            LumeInvocationError.versionMismatch(found: SemanticVersion([0, 5, 4]), required: LumePin.version),
            claimedVersion: LumePin.version
        )
        #expect(mismatched == .init(
            version: "0.5.4",
            verified: true,
            problem: .runtimeIncompatible(found: "0.5.4", required: "0.5.3")
        ))
    }

    @Test func successfulProbePublishesOnlyCapabilities() {
        let capabilities = RuntimeVersionInfo.LumeCapabilities(
            unattendedTahoe: true,
            createRunAttachStorage: true,
            detachedRun: true,
            nativeAttach: true,
            vncCanBeDisabled: false
        )
        #expect(LumeDiscoveryReport.succeeded(.init(version: LumePin.version, capabilities: capabilities)) == .init(
            version: "0.5.3",
            verified: true,
            capabilities: capabilities
        ))
    }
}
