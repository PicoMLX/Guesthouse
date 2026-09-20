import Foundation
import Testing
@testable import GuesthouseCore

struct PreflightCheckTests {
    @Test func completeBaselinePreservesTypedFactsAndPlanningSummary() {
        let now = Date(timeIntervalSince1970: 123)
        let report = PreflightCheck.run(snapshot: healthy(), now: now)
        #expect(report.canProceed)
        #expect(report.results.map(\.kind) == [.architecture, .macOSVersion, .memory, .freeDisk, .codexDesktop])
        #expect(report.results.allSatisfy { $0.severity == .pass })
        #expect(report.checkedAt == now)
        #expect(report.powerSource == .externalPower)
        #expect(report.storage.runtimeDownloadEstimateBytes == 50_000_000)
        #expect(report.storage.restoreImageEstimateBytes == 16_000_000_000)
        #expect(report.storage.guestDiskBytes == 160_000_000_000)
        #expect(report.storage.firstSetupAllowanceBytes == 200_000_000_000)
        #expect(report.storage.locationDescription.contains("must verify"))
    }

    @Test func anUnobservedHostNeverPasses() {
        let report = PreflightCheck.run(snapshot: HostProbeSnapshot())
        #expect(!report.canProceed)
        #expect(report.results.allSatisfy { $0.isBlocking })
        #expect(report.result(.architecture) == .architectureUnknown)
        #expect(report.result(.macOSVersion) == .macOSUnknown)
        #expect(report.result(.memory) == .memoryUnknown)
        #expect(report.result(.freeDisk) == .diskUnavailable(.storageRootUnknown))
        #expect(report.result(.codexDesktop) == .codexUnavailable)
    }

    @Test(arguments: [
        (CPUArchitecture.appleSilicon, CPUArchitecture.appleSilicon, PreflightResult.Severity.pass),
        (.intel, .intel, .pass), (.intel, .appleSilicon, .fail), (.appleSilicon, .intel, .fail),
        (.unknown, .appleSilicon, .fail), (.unknown, .intel, .fail), (.unknown, .unknown, .fail),
        (.appleSilicon, .unknown, .fail), (.intel, .unknown, .fail),
    ])
    func architecturePoliciesRemainTruthful(_ values: (CPUArchitecture, CPUArchitecture, PreflightResult.Severity)) throws {
        var policy = ResourcePolicy.standard
        policy.requiredArchitecture = values.1
        let result = try #require(PreflightCheck.run(snapshot: healthy(architecture: values.0), policy: policy).result(.architecture))
        #expect(result.severity == values.2)
    }

    @Test func nondefaultArchitectureMessageNamesBothObservedAndRequired() throws {
        var policy = ResourcePolicy.standard
        policy.requiredArchitecture = .intel
        let result = try #require(PreflightCheck.run(snapshot: healthy(), policy: policy).result(.architecture))
        #expect(result == .architectureMismatch(found: .appleSilicon, required: .intel))
        #expect(result.userMessage == "This Mac uses Apple silicon; the selected policy requires Intel.")
    }

    @Test(arguments: [
        (nil as SemanticVersion?, PreflightResult.Severity.undetermined),
        (SemanticVersion([0]), .fail), (SemanticVersion([26, 3]), .fail),
        (SemanticVersion([26, 4]), .pass), (SemanticVersion([27]), .pass),
    ])
    func operatingSystemBoundaries(_ values: (SemanticVersion?, PreflightResult.Severity)) throws {
        let result = try #require(PreflightCheck.run(snapshot: healthy(version: values.0)).result(.macOSVersion))
        #expect(result.severity == values.1)
    }

    @Test(arguments: [
        (nil as UInt64?, PreflightResult.Severity.undetermined), (0, .fail), (17_179_869_184, .fail),
        (25_769_803_776, .warn), (34_359_738_368, .pass), (68_719_476_736, .pass),
    ])
    func memoryFloorPrecedesRecommendation(_ values: (UInt64?, PreflightResult.Severity)) throws {
        let result = try #require(PreflightCheck.run(snapshot: healthy(memory: values.0)).result(.memory))
        #expect(result.severity == values.1)
    }

    @Test func limitedMemoryWarningDoesNotBlockAnOtherwiseReadyHost() {
        let report = PreflightCheck.run(snapshot: healthy(memory: 25_769_803_776))
        #expect(report.canProceed)
        #expect(report.result(.memory) == .memoryLimited(foundBytes: 25_769_803_776, recommendedBytes: 34_359_738_368))
    }

    @Test func contradictoryRecommendationCannotHideARequiredMemoryFailure() {
        var policy = ResourcePolicy.standard
        policy.minimumMemoryBytes = 51_539_607_552
        let report = PreflightCheck.run(snapshot: healthy(), policy: policy)
        #expect(!report.canProceed)
        #expect(report.result(.memory) == .memoryFailure(.unsupportedHost(
            .insufficientMemory(foundBytes: 34_359_738_368, minimumBytes: 51_539_607_552))))
    }

    @Test func overflowStillBlocksWhenAvailableMemoryIsMaximum() {
        var policy = ResourcePolicy.standard
        policy.hostMemoryHeadroomBytes = .max
        let report = PreflightCheck.run(snapshot: healthy(memory: .max), policy: policy)
        #expect(!report.canProceed)
        #expect(report.result(.memory) == .memoryFailure(.unsupportedHost(
            .insufficientMemory(foundBytes: .max, minimumBytes: .max))))
    }

    @Test(arguments: [
        (UInt64(0), PreflightResult.Severity.fail), (199_999_999_999, .fail),
        (200_000_000_000, .pass), (.max, .pass),
    ])
    func firstSetupDiskThresholdIsNotThePerOperationMargin(_ values: (UInt64, PreflightResult.Severity)) throws {
        let result = try #require(PreflightCheck.run(snapshot: healthy(disk: .available(bytes: values.0))).result(.freeDisk))
        #expect(result.severity == values.1)
    }

    @Test(arguments: HostProbeError.allCases)
    func everyUnavailableDiskBlocksAndPreservesRecovery(failure: HostProbeError) throws {
        let report = PreflightCheck.run(snapshot: healthy(disk: .unavailable(failure)))
        let result = try #require(report.result(.freeDisk))
        #expect(!report.canProceed)
        #expect(result == .diskUnavailable(failure))
        #expect(result.severity == .undetermined)
        #expect(result.recoveryActions == failure.recoveryActions)
    }

    @Test(arguments: [
        (CodexDesktopObservation.notFound, PreflightResult.Severity.warn, true),
        (.unavailable, .undetermined, false), (.installed(version: nil, build: nil), .pass, true),
        (.installed(version: SemanticVersion([2]), build: SemanticVersion([456])), .pass, true),
    ])
    func missingApplicationIsNotFailedDiscovery(_ values: (CodexDesktopObservation, PreflightResult.Severity, Bool)) throws {
        let report = PreflightCheck.run(snapshot: healthy(codex: values.0))
        let result = try #require(report.result(.codexDesktop))
        #expect(result.severity == values.1)
        #expect(report.canProceed == values.2)
    }

    @Test(arguments: [
        PreflightResult.architectureSupported(.appleSilicon), .architectureUnknown,
        .architectureMismatch(found: .intel, required: .appleSilicon),
        .macOSSupported(SemanticVersion([26, 4])), .macOSUnknown,
        .macOSTooOld(found: SemanticVersion([26, 3]), minimum: SemanticVersion([26, 4])),
        .memorySufficient(bytes: .max), .memoryLimited(foundBytes: 24, recommendedBytes: 32), .memoryUnknown,
        .memoryFailure(.unsupportedHost(.insufficientMemory(foundBytes: 0, minimumBytes: .max))),
        .diskSufficient(bytes: .max), .insufficientDisk(requiredBytes: .max, availableBytes: 0),
        .diskUnavailable(.capacityUnavailable), .codexInstalled(version: nil, build: nil),
        .codexNotFound, .codexUnavailable,
    ])
    func everyResultCasePreservesItsFactsAndFixedMessage(result: PreflightResult) throws {
        let restored = try JSONDecoder().decode(PreflightResult.self, from: JSONEncoder().encode(result))
        #expect(restored == result)
        #expect(restored.kind == result.kind)
        #expect(restored.severity == result.severity)
        #expect(!restored.userMessage.isEmpty)
        #expect(!restored.isBlocking || !restored.recoveryActions.isEmpty)
    }

    @Test func anUnknownResultCannotAcquirePassingSeverity() throws {
        let data = Data(#"{"futureCheck": {}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PreflightResult.self, from: data) }
    }

    @Test(arguments: PreflightCheckKind.allCases)
    func omittingAnyRequiredCheckBlocks(kind: PreflightCheckKind) {
        let complete = PreflightCheck.run(snapshot: healthy())
        let partial = replacingResults(in: complete, with: complete.results.filter { $0.kind != kind })
        #expect(!partial.canProceed)
        #expect(partial.result(kind) == nil)
    }

    @Test func emptyAndDuplicatedReportsDoNotProceed() {
        let complete = PreflightCheck.run(snapshot: healthy())
        #expect(!replacingResults(in: complete, with: []).canProceed)
        #expect(!replacingResults(in: complete, with: complete.results + [.architectureSupported(.appleSilicon)]).canProceed)
        let duplicated = Array(repeating: PreflightResult.architectureSupported(.appleSilicon), count: 5)
        #expect(!replacingResults(in: complete, with: duplicated).canProceed)
    }

    @Test(arguments: [PowerSource.externalPower, .battery, .unknown])
    func powerIsPreservedWithoutFabricatingResourceReadiness(power: PowerSource) {
        let report = PreflightCheck.run(snapshot: healthy(power: power))
        #expect(report.powerSource == power)
        #expect(report.canProceed)
    }

    @Test func reportRoundTripDoesNotAcceptAnEncodedContinueOverrideOrRawDetail() throws {
        let report = PreflightCheck.run(snapshot: HostProbeSnapshot(), now: Date(timeIntervalSince1970: 123))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object["canProceed"] = true
        object["detail"] = "untrusted report text"
        object["storageRootPath"] = "/untrusted/private/path"
        let restored = try JSONDecoder().decode(PreflightReport.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored == report)
        #expect(!restored.canProceed)
        #expect(!String(decoding: try JSONEncoder().encode(restored), as: UTF8.self).contains("untrusted"))
    }

    @Test func diskFailureCannotBeRelabeledWithEncodedKindOrSeverity() throws {
        let result = PreflightResult.diskUnavailable(.volumeIdentityChanged)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        object["kind"] = "codexDesktop"
        object["severity"] = "pass"
        let restored = try JSONDecoder().decode(PreflightResult.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored == result)
        #expect(restored.kind == .freeDisk)
        #expect(restored.isBlocking)
        #expect(restored.recoveryActions == [.inspectState, .cancel])
    }

    @Test func nondefaultPlanningAmountsArePreservedWithoutAPathField() {
        var policy = ResourcePolicy.standard
        policy.runtimeDownloadEstimateBytes = 1
        policy.restoreImageEstimateBytes = 2
        policy.firstSetupAllowanceBytes = 3
        let summary = StorageSummary(policy: policy, preset: .dualVMExperiment)
        #expect(summary.runtimeDownloadEstimateBytes == 1)
        #expect(summary.restoreImageEstimateBytes == 2)
        #expect(summary.firstSetupAllowanceBytes == 3)
        #expect(summary.guestDiskBytes == 160_000_000_000)
    }

    private func healthy(
        architecture: CPUArchitecture = .appleSilicon, version: SemanticVersion? = SemanticVersion([26, 4]),
        memory: UInt64? = 34_359_738_368, disk: HostDiskObservation = .available(bytes: 200_000_000_000),
        codex: CodexDesktopObservation = .installed(version: SemanticVersion([1, 2]), build: nil),
        power: PowerSource = .externalPower
    ) -> HostProbeSnapshot {
        HostProbeSnapshot(cpuArchitecture: architecture, operatingSystemVersion: version,
                          physicalMemoryBytes: memory, powerSource: power, disk: disk, codexDesktop: codex)
    }

    private func replacingResults(in report: PreflightReport, with results: [PreflightResult]) -> PreflightReport {
        PreflightReport(results: results, storage: report.storage, powerSource: report.powerSource, checkedAt: report.checkedAt)
    }
}
