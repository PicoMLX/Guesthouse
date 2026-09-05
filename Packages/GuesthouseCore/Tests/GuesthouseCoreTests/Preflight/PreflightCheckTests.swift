import Foundation
import Testing
@testable import GuesthouseCore

struct StubProbe: HostProbe {
    var cpuArchitecture: CPUArchitecture = .appleSilicon
    var operatingSystemVersion = SemanticVersion([26, 5, 2])
    var operatingSystemBuild: String? = "25F84"
    var physicalMemoryBytes: UInt64 = 32 * ResourcePreset.gibibyte
    var powerSource: PowerSource = .externalPower
    var free: Result<UInt64, any Error> = .success(500 * ResourcePreset.gigabyte)
    var applications: [String: InstalledApplication] = [:]

    func freeBytes(at url: URL) throws -> UInt64 { try free.get() }
    func installedApplication(bundleIdentifier: String) -> InstalledApplication? { applications[bundleIdentifier] }
}

@Suite struct PreflightCheckTests {
    let root = URL(fileURLWithPath: "/Users/dev/Library/Application Support/Guesthouse")
    struct ProbeFailure: Error {}

    func run(_ probe: StubProbe) -> PreflightReport {
        PreflightCheck.run(probe: probe, storageRoot: root, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func healthyHostPassesEverythingExceptMissingCodexWhichWarns() {
        var probe = StubProbe()
        probe.applications["com.openai.chat"] = InstalledApplication(url: URL(fileURLWithPath: "/Applications/ChatGPT.app"), version: "1.2.3", build: "456")
        let report = run(probe)
        #expect(report.canProceed)
        for kind in PreflightCheckKind.allCases {
            guard case .pass(let detail) = report.result(kind)!.outcome else { Issue.record("\(kind) not pass"); continue }
            #expect(!detail.value.isEmpty)
        }
        #expect(report.result(.macOSVersion)!.outcome == .pass(detail: "macOS 26.5.2 (25F84)"))
        #expect(report.result(.codexDesktop)!.outcome == .pass(detail: "Codex desktop 1.2.3 (456) at /Applications/ChatGPT.app"))
        #expect(report.storage.storageRootPath == root.path)
        #expect(report.storage.guestDiskBytes == ResourcePreset.recommended.diskBytes)
        #expect(report.powerSource == .externalPower)

        let missing = run(StubProbe())
        #expect(missing.canProceed)
        guard case .warn(let detail, _) = missing.result(.codexDesktop)!.outcome else { Issue.record("expected warn"); return }
        #expect(detail.value.contains("not installed"))
    }

    @Test func intelHostFails() {
        var probe = StubProbe(); probe.cpuArchitecture = .intel
        let report = run(probe)
        #expect(!report.canProceed)
        #expect(report.result(.architecture)!.outcome == .fail(.unsupportedHost(.wrongArchitecture(found: SanitizedText("Intel"), required: "Apple silicon"))))
    }

    @Test func oldMacOSFails() {
        var probe = StubProbe(); probe.operatingSystemVersion = SemanticVersion([26, 3, 9])
        let report = run(probe)
        #expect(report.result(.macOSVersion)!.outcome == .fail(.unsupportedHost(.macOSTooOld(found: "26.3.9", minimum: "26.4"))))
    }

    @Test func memoryTiersPassWarnFail() {
        var probe = StubProbe()
        probe.physicalMemoryBytes = 24 * ResourcePreset.gibibyte
        guard case .warn(let detail, _) = run(probe).result(.memory)!.outcome else { Issue.record("expected warn"); return }
        #expect(detail.value.contains("32 GB is recommended"))
        #expect(run(probe).canProceed)

        probe.physicalMemoryBytes = 8 * ResourcePreset.gibibyte
        #expect(run(probe).result(.memory)!.outcome == .fail(.unsupportedHost(.insufficientMemory(foundBytes: 8 * ResourcePreset.gibibyte, minimumBytes: 24 * ResourcePreset.gibibyte))))
        #expect(!run(probe).canProceed)

        // Exactly the guest allocation leaves nothing for the host: blocked, not warned.
        probe.physicalMemoryBytes = 16 * ResourcePreset.gibibyte
        #expect(run(probe).result(.memory)!.isFailure)
        probe.physicalMemoryBytes = 24 * ResourcePreset.gibibyte
        #expect(!run(probe).result(.memory)!.isFailure)
    }

    @Test func unknownArchitectureIsNamedAndRetryable() {
        var probe = StubProbe(); probe.cpuArchitecture = .unknown
        let report = run(probe)
        #expect(report.result(.architecture)!.outcome == .fail(.unsupportedHost(.architectureUnknown)))
        #expect(GuesthouseError.unsupportedHost(.architectureUnknown).recoveryActions.first == .retry)
    }

    @Test func storagePathsAreSanitizedInWarningsAndTheSummary() {
        var probe = StubProbe(); probe.free = .failure(ProbeFailure())
        let hostile = URL(fileURLWithPath: "/Volumes/Ext\u{202E}gnol/Guesthouse")
        let report = PreflightCheck.run(probe: probe, storageRoot: hostile, now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case .undetermined(let detail, _) = report.result(.freeDisk)!.outcome else { Issue.record("expected undetermined"); return }
        #expect(!detail.value.contains("\u{202E}"))
        #expect(!report.storage.storageRootPath.contains("\u{202E}"))
    }

    @Test func largeOperationRequirementsThatOverflowAreInsufficient() {
        let probe = StubProbe()
        _ = probe
        #expect(throws: GuesthouseError.self) {
            try LargeOperationPreflight.check(freeBytes: 500 * ResourcePreset.gigabyte, requiredBytes: UInt64.max - 1, volumePath: "/")
        }
    }

    @Test func freeSpaceIsReadFromTheNearestExistingAncestor() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "does-not-exist-\(UUID().uuidString)/nested/Guesthouse")
        #expect(try SystemHostProbe().freeBytes(at: missing) > 0)
    }

    @Test func blockingMinimumIsEvaluatedBeforeTheRecommendation() {
        var policy = ResourcePolicy()
        policy.minimumMemoryBytes = 48 * ResourcePreset.gibibyte
        policy.recommendedMemoryBytes = 32 * ResourcePreset.gibibyte
        #expect(!policy.isWellFormed)
        #expect(ResourcePolicy.standard.isWellFormed)
        let report = PreflightCheck.run(probe: StubProbe(), policy: policy, storageRoot: root)
        #expect(report.result(.memory)!.isFailure, "32 GB is above the recommendation but below the contradictory minimum")
    }

    @Test func applicationMetadataIsSanitizedBeforePresentation() {
        var probe = StubProbe()
        probe.applications["com.openai.chat"] = InstalledApplication(url: URL(fileURLWithPath: "/Applications/Chat\u{202E}GPT.app"), version: "1.2\n.3", build: String(repeating: "9", count: 300))
        guard case .pass(let detail) = run(probe).result(.codexDesktop)!.outcome else { Issue.record("expected pass"); return }
        #expect(!detail.value.contains("\u{202E}"))
        #expect(!detail.value.contains("\n"))
        #expect(!detail.value.contains(String(repeating: "9", count: 100)))
    }

    @Test func lowDiskFailsWithPreciseNumbersAndUnknownDiskBlocks() {
        var probe = StubProbe()
        probe.free = .success(50 * ResourcePreset.gigabyte)
        #expect(run(probe).result(.freeDisk)!.outcome == .fail(.insufficientDisk(requiredBytes: 200 * ResourcePreset.gigabyte, availableBytes: 50 * ResourcePreset.gigabyte, volumePath: SanitizedText(root.path))))

        probe.free = .failure(ProbeFailure())
        guard case .undetermined(_, let recovery) = run(probe).result(.freeDisk)!.outcome else { Issue.record("expected undetermined"); return }
        #expect(recovery == [.retry, .openSettings])
        #expect(!run(probe).canProceed, "a check that could not be made never counts as satisfied")
    }

    @Test func anUnknownArchitectureFailsEvenWhenThePolicyAsksForOne() {
        var probe = StubProbe(); probe.cpuArchitecture = .unknown
        var policy = ResourcePolicy(); policy.requiredArchitecture = .unknown
        let report = PreflightCheck.run(probe: probe, policy: policy, storageRoot: root, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(report.result(.architecture)!.outcome == .fail(.unsupportedHost(.architectureUnknown)))
        #expect(!report.canProceed)
    }

    @Test func anImpossibleMemoryFloorIsNeverSatisfied() {
        var policy = ResourcePolicy(); policy.hostMemoryHeadroomBytes = UInt64.max - 1
        let preset = ResourcePreset(name: "Test", memoryBytes: 16 * ResourcePreset.gibibyte, cpuCount: 4, diskBytes: ResourcePreset.recommended.diskBytes, verification: .experimental)!
        let report = PreflightCheck.run(probe: StubProbe(), policy: policy, storageRoot: root, preset: preset, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(report.result(.memory)!.isFailure, "a requirement that overflows can never be met")
    }

    @Test func anUnrepresentableRequirementReportsItselfAsSuch() {
        let error = #expect(throws: GuesthouseError.self) {
            try LargeOperationPreflight.check(freeBytes: 500 * ResourcePreset.gigabyte, requiredBytes: UInt64.max - 1, volumePath: "/x")
        }
        guard case .insufficientDisk(let required, let available, _)? = error else { Issue.record("expected insufficientDisk"); return }
        #expect(required == UInt64.max, "the reported requirement is not the wrapped remainder")
        #expect(available == 500 * ResourcePreset.gigabyte)
    }

    @Test func anUnavailableVolumeBlocksSetup() {
        struct UnmountedProbe: HostProbe {
            var cpuArchitecture: CPUArchitecture = .appleSilicon
            var operatingSystemVersion = SemanticVersion([26, 5, 2])
            var operatingSystemBuild: String? = "25F84"
            var physicalMemoryBytes: UInt64 = 64 * ResourcePreset.gibibyte
            var powerSource: PowerSource = .externalPower
            func freeBytes(at url: URL) throws -> UInt64 { throw HostProbeError.volumeUnavailable(path: "/Volumes/External/Guesthouse") }
            func installedApplication(bundleIdentifier: String) -> InstalledApplication? { nil }
        }
        let report = PreflightCheck.run(probe: UnmountedProbe(), storageRoot: URL(fileURLWithPath: "/Volumes/External/Guesthouse"), now: Date(timeIntervalSince1970: 1_800_000_000))
        guard case .undetermined(let detail, let recovery) = report.result(.freeDisk)!.outcome else { Issue.record("expected undetermined"); return }
        #expect(detail.value.contains("not available"))
        #expect(recovery.first == .retry)
        #expect(!report.canProceed, "there is no disk to check, so setup does not continue")
    }

    @Test func theArchitectureTextFollowsTheConfiguredPolicy() {
        var policy = ResourcePolicy(); policy.requiredArchitecture = .intel
        var probe = StubProbe(); probe.cpuArchitecture = .intel
        guard case .pass(let detail) = PreflightCheck.run(probe: probe, policy: policy, storageRoot: root, now: Date(timeIntervalSince1970: 1_800_000_000)).result(.architecture)!.outcome else { Issue.record("expected pass"); return }
        #expect(detail == "Intel")
        probe.cpuArchitecture = .appleSilicon
        let failure = PreflightCheck.run(probe: probe, policy: policy, storageRoot: root, now: Date(timeIntervalSince1970: 1_800_000_000)).result(.architecture)!.outcome
        #expect(failure == .fail(.unsupportedHost(.wrongArchitecture(found: SanitizedText("Apple silicon"), required: "Intel"))))
        if case .fail(let error) = failure {
            #expect(error.userMessage.contains("Apple silicon") && error.userMessage.contains("Intel"))
        }
    }

    /// Both sides of the mismatch are sanitized where the value is built, not where it is shown,
    /// so what a decoded payload put in either is bounded and redacted in the encoded form too.
    @Test func theRequiredArchitectureIsSanitizedInTheEncodedPayloadToo() throws {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let error = GuesthouseError.unsupportedHost(.wrongArchitecture(found: "Intel", required: SanitizedText("Apple silicon \(token)")))
        #expect(!error.userMessage.contains(token))
        let json = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
        #expect(!json.contains(token))
        #expect(json.contains("[redacted:github-token]"))
        let restored = try JSONDecoder().decode(GuesthouseError.self, from: Data(json.utf8))
        #expect(restored == error)
    }

    @Test func aReportMissingACheckNeverProceeds() {
        let full = PreflightCheck.run(probe: StubProbe(), storageRoot: root, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(full.canProceed)
        let partial = PreflightReport(results: Array(full.results.dropLast()), storage: full.storage, powerSource: full.powerSource, checkedAt: full.checkedAt)
        #expect(!partial.canProceed, "a report that answers only some checks is not a passing report")
        let empty = PreflightReport(results: [], storage: full.storage, powerSource: full.powerSource, checkedAt: full.checkedAt)
        #expect(!empty.canProceed)
    }

    @Test func aDanglingOrFileDestinationIsNeverMeasuredOnAnotherDisk() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Destination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let probe = SystemHostProbe()
        let dangling = base.appending(path: "external")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: URL(fileURLWithPath: "/Volumes/NotMounted/Guesthouse"))
        #expect(throws: HostProbeError.self) { try probe.freeBytes(at: dangling.appending(path: "store")) }
        let file = base.appending(path: "file")
        try Data("x".utf8).write(to: file)
        #expect(throws: HostProbeError.notADirectory(path: file.path)) { try probe.freeBytes(at: file.appending(path: "store")) }
        #expect(throws: Never.self) { _ = try probe.freeBytes(at: base.appending(path: "fresh/store")) }
        for error in [HostProbeError.volumeUnavailable(path: "/x"), .notADirectory(path: "/x")] {
            #expect(!error.recoveryActions.isEmpty)
            #expect(!error.userMessage.isEmpty)
        }
    }

    @Test func anUnwritableDestinationIsNotReportedAsUsableSpace() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Unwritable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)
        // Permission bits do not restrain root, so only an ordinary user can prove this.
        if getuid() != 0 {
            let probe = SystemHostProbe()
            #expect(throws: HostProbeError.destinationNotWritable(path: base.path)) { try probe.freeBytes(at: base) }
            #expect(throws: HostProbeError.destinationNotWritable(path: base.path)) { try probe.freeBytes(at: base.appending(path: "Guesthouse")) }
        }

        var stub = StubProbe()
        stub.free = .failure(HostProbeError.destinationNotWritable(path: root.path))
        let report = run(stub)
        guard case .undetermined(let detail, let recovery) = report.result(.freeDisk)!.outcome else { Issue.record("expected undetermined"); return }
        #expect(detail.value.contains("cannot write"))
        #expect(recovery.contains(.openSettings))
        #expect(!report.canProceed, "a destination that cannot be written is not a satisfied storage check")
    }

    @Test func theOperatingSystemBuildIsSanitizedBeforeItReachesTheResult() {
        var probe = StubProbe()
        probe.operatingSystemBuild = "25F84\u{202E}\n" + String(repeating: "9", count: 300)
        guard case .pass(let detail) = run(probe).result(.macOSVersion)!.outcome else { Issue.record("expected pass"); return }
        #expect(!detail.value.contains("\u{202E}"))
        #expect(!detail.value.contains("\n"))
        #expect(!detail.value.contains(String(repeating: "9", count: 100)))
    }

    @Test func anUnrepresentableRequirementIsNamedAtFullSize() {
        let error = GuesthouseError.insufficientDisk(requiredBytes: .max, availableBytes: 512, volumePath: SanitizedText("/Volumes/Work"))
        #expect(error.userMessage.contains(UInt64.max.formatted()), "a requirement above Int64 must not be presented as half of itself")
    }

    @Test func aDestinationThatCannotBeTraversedIsNotUsableSpace() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Unsearchable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path) }
        // Writable but not searchable: nothing can be created in it, so its capacity is not
        // space a development Mac can use.
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: base.path)
        // Permission bits do not restrain root, so only an ordinary user can prove this.
        if getuid() != 0 {
            #expect(throws: HostProbeError.destinationNotWritable(path: base.path)) { try SystemHostProbe().freeBytes(at: base) }
        }
    }

    @Test func onlyAFilesystemDenialRulesOutTheDestination() {
        #expect(SystemHostProbe.rulesOutDestination(EACCES))
        #expect(SystemHostProbe.rulesOutDestination(EROFS), "a read-only volume cannot be written by any process")
        #expect(!SystemHostProbe.rulesOutDestination(EPERM), "the sandboxed app's own refusal says nothing about a folder the runtime service writes")
    }

    @Test func aLeftoverMountPointIsNeverMeasuredOnTheStartupDisk() throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "Volumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: container) }
        let leftover = container.appending(path: "External")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let probe = SystemHostProbe()
        #expect(throws: HostProbeError.volumeUnavailable(path: leftover.path)) {
            try probe.freeBytes(at: leftover.appending(path: "Guesthouse"), mountContainer: container.path)
        }
        #expect(throws: HostProbeError.volumeUnavailable(path: leftover.path)) {
            try probe.freeBytes(at: leftover, mountContainer: container.path)
        }
        // A destination that names no mount point is still measured normally.
        #expect(throws: Never.self) { _ = try probe.freeBytes(at: leftover.appending(path: "Guesthouse")) }
    }

    /// A link outside the folder that holds mount points can lead inside one. The spelled path
    /// names no mount point, so the leftover-folder check used to be skipped while the capacity
    /// lookup followed the link and answered with the startup disk's space for a volume that is
    /// not mounted.
    @Test func aLinkIntoALeftoverMountPointIsNotMeasuredEither() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "LinkedVolume-\(UUID().uuidString)")
        let container = base.appending(path: "Volumes")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let leftover = container.appending(path: "External")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = base.appending(path: "Development Macs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: leftover)
        #expect(SystemHostProbe.volumeMountPoint(of: link, container: container.path) == nil, "the path as spelled names no mount point")
        let probe = SystemHostProbe()
        let unmounted = leftover.resolvingSymlinksInPath().path
        #expect(throws: HostProbeError.volumeUnavailable(path: unmounted)) {
            try probe.freeBytes(at: link, mountContainer: container.path)
        }
        #expect(throws: HostProbeError.volumeUnavailable(path: unmounted)) {
            try probe.freeBytes(at: link.appending(path: "Guesthouse"), mountContainer: container.path)
        }
    }

    @Test func everyFailureCarriesARecoveryAction() {
        var probe = StubProbe()
        probe.cpuArchitecture = .intel
        probe.operatingSystemVersion = SemanticVersion([15, 0])
        probe.physicalMemoryBytes = 4 * ResourcePreset.gibibyte
        probe.free = .success(1)
        for result in run(probe).results {
            if case .fail(let error) = result.outcome {
                #expect(!error.recoveryActions.isEmpty, Comment(rawValue: result.kind.rawValue))
                #expect(!error.userMessage.isEmpty)
            }
        }
    }

    @Test func largeOperationAddsMarginAndReportsTheRealRequirement() throws {
        try LargeOperationPreflight.check(freeBytes: 60 * ResourcePreset.gigabyte, requiredBytes: 40 * ResourcePreset.gigabyte, volumePath: "/")
        #expect(throws: GuesthouseError.insufficientDisk(requiredBytes: 50 * ResourcePreset.gigabyte, availableBytes: 45 * ResourcePreset.gigabyte, volumePath: "/")) {
            try LargeOperationPreflight.check(freeBytes: 45 * ResourcePreset.gigabyte, requiredBytes: 40 * ResourcePreset.gigabyte, volumePath: "/")
        }
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let report = run(StubProbe())
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(PreflightReport.self, from: data) == report)
    }

    @Test func systemProbeReturnsPlausibleValuesOnThisMac() throws {
        let probe = SystemHostProbe()
        #expect(probe.physicalMemoryBytes > 0)
        #expect(probe.operatingSystemVersion >= SemanticVersion([14]))
        #expect(try probe.freeBytes(at: FileManager.default.temporaryDirectory) > 0)
        #expect(probe.installedApplication(bundleIdentifier: "com.apple.finder")?.url.lastPathComponent == "Finder.app")
        #expect(probe.installedApplication(bundleIdentifier: "com.example.does.not.exist") == nil)
    }

    /// A guest allocation plus host headroom that cannot be represented is a failure in its own
    /// right. Deciding it with a `UInt64.max` floor let a probe that answers `UInt64.max` past
    /// it: `.max < .max` is false, so the check recorded a pass for an allocation no Mac has.
    @Test func anUnrepresentableMemoryFloorAlwaysFails() throws {
        var policy = ResourcePolicy()
        policy.hostMemoryHeadroomBytes = .max
        let preset = try #require(ResourcePreset(name: "huge", memoryBytes: 1, cpuCount: 4, diskBytes: 1, verification: .experimental))
        var probe = StubProbe()
        probe.physicalMemoryBytes = .max
        let report = PreflightCheck.run(probe: probe, policy: policy, storageRoot: root, preset: preset, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(report.result(.memory)!.outcome == .fail(.unsupportedHost(.insufficientMemory(foundBytes: .max, minimumBytes: .max))))
        #expect(!report.canProceed)
    }

    /// A result does not only come from `run`. One decoded from a diagnostics file or received
    /// over the wire carries whatever the sender put in it, and `detail` is presented and
    /// re-encoded, so it is bounded and redacted by its own type rather than by its author.
    @Test func aDecodedDetailIsSanitizedLikeEveryOtherOutsideValue() throws {
        let hostile = "one-time code is AB12-CD34 \u{202E}reversed\nsecond line " + String(repeating: "9", count: 2_000)
        let json = try JSONEncoder().encode(["pass": ["detail": hostile]])
        let outcome = try JSONDecoder().decode(PreflightResult.Outcome.self, from: json)
        guard case .pass(let detail) = outcome else { Issue.record("expected pass"); return }
        #expect(!detail.value.contains("AB12-CD34"))
        #expect(!detail.value.contains("\u{202E}"))
        #expect(!detail.value.contains("\n"))
        #expect(detail.value.unicodeScalars.count <= SanitizedText.maximumLimit + 1)
        // What `encode(to:)` writes is the sanitized text, not what came in.
        let reencoded = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
        #expect(!reencoded.contains("AB12-CD34"))
        // A detail built by `run` is a sentence, and survives the round trip whole.
        let advice = PreflightResult.detail(String(repeating: "a", count: 300))
        #expect(advice.value.unicodeScalars.count == 300)
        #expect(try JSONDecoder().decode(SanitizedText.self, from: JSONEncoder().encode(advice)) == advice)
    }
}
