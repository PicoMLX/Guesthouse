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
            #expect(!detail.isEmpty)
        }
        #expect(report.result(.macOSVersion)!.outcome == .pass(detail: "macOS 26.5.2 (25F84)"))
        #expect(report.result(.codexDesktop)!.outcome == .pass(detail: "Codex desktop 1.2.3 (456) at /Applications/ChatGPT.app"))
        #expect(report.storage.storageRootPath == root.path)
        #expect(report.storage.guestDiskBytes == ResourcePreset.recommended.diskBytes)
        #expect(report.powerSource == .externalPower)

        let missing = run(StubProbe())
        #expect(missing.canProceed)
        guard case .warn(let detail, _) = missing.result(.codexDesktop)!.outcome else { Issue.record("expected warn"); return }
        #expect(detail.contains("not installed"))
    }

    @Test func intelHostFails() {
        var probe = StubProbe(); probe.cpuArchitecture = .intel
        let report = run(probe)
        #expect(!report.canProceed)
        #expect(report.result(.architecture)!.outcome == .fail(.unsupportedHost(.notAppleSilicon)))
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
        #expect(detail.contains("32 GB is recommended"))
        #expect(run(probe).canProceed)

        probe.physicalMemoryBytes = 8 * ResourcePreset.gibibyte
        #expect(run(probe).result(.memory)!.outcome == .fail(.unsupportedHost(.insufficientMemory(foundBytes: 8 * ResourcePreset.gibibyte, minimumBytes: 16 * ResourcePreset.gibibyte))))
        #expect(!run(probe).canProceed)
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
        #expect(!detail.contains("\u{202E}"))
        #expect(!detail.contains("\n"))
        #expect(!detail.contains(String(repeating: "9", count: 100)))
    }

    @Test func lowDiskFailsWithPreciseNumbersAndUnknownDiskWarns() {
        var probe = StubProbe()
        probe.free = .success(50 * ResourcePreset.gigabyte)
        #expect(run(probe).result(.freeDisk)!.outcome == .fail(.insufficientDisk(requiredBytes: 200 * ResourcePreset.gigabyte, availableBytes: 50 * ResourcePreset.gigabyte, volumePath: SanitizedText(root.path))))

        probe.free = .failure(ProbeFailure())
        guard case .warn(_, let recovery) = run(probe).result(.freeDisk)!.outcome else { Issue.record("expected warn"); return }
        #expect(recovery == [.retry])
        #expect(run(probe).canProceed)
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
}
