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

    @Test func fixedStatesDistinguishCheckingAndMissingRuntime() {
        #expect(LumeDiscoveryReport.checking == .init(version: nil, verified: false))
        #expect(LumeDiscoveryReport.missing == .init(
            version: nil,
            verified: false,
            problem: .runtimeMissing
        ))
    }

    @Test func storageFailuresKeepTheirSanitizedCauseAndRecovery() {
        let cases: [(RuntimeStorageError, RuntimeStorageProblem.Kind, String)] = [
            (.protectionDrift(path: "/private/runtime/vms", reason: "permissions are not 0700"), .protectionDrift, "permissions are not 0700"),
            (.insecureDirectory(path: "/private/runtime/vms", reason: "symbolic link"), .insecureDirectory, "symbolic link"),
            (.unwritable(path: "/private/runtime/vms", reason: "No space left on device"), .unwritable, "No space left on device"),
        ]

        for (error, kind, detail) in cases {
            let expectedProblem = RuntimeStorageProblem(
                kind: kind,
                path: "/private/runtime/vms",
                detail: detail
            )
            let report = LumeDiscoveryReport.storageUnavailable(error)
            #expect(report == .init(
                version: nil,
                verified: false,
                problem: .runtimeStorageUnavailable(expectedProblem)
            ))
            #expect(!report.problem!.recoveryActions.contains(.openSettings))
            #expect(!report.problem!.recoveryActions.contains(.retry))
        }
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
            version: nil,
            verified: false,
            problem: .runtimeProbeFailed
        ))
        #expect(LumeDiscoveryReport.failedProbe(LumeInvocationError.storageMismatch, claimedVersion: LumePin.version) == .init(
            version: nil,
            verified: false,
            problem: .runtimeProbeFailed
        ))
        let storageError = RuntimeStorageError.protectionDrift(
            path: "/private/runtime",
            reason: "permissions are not 0700"
        )
        #expect(LumeDiscoveryReport.failedProbe(storageError, claimedVersion: LumePin.version)
            == LumeDiscoveryReport.storageUnavailable(storageError))
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
