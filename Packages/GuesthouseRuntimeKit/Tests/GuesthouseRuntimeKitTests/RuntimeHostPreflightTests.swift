import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

struct RuntimeHostPreflightTests {
    @Test func composesAllFiveResultsUsingRuntimeDefaults() {
        let report = RuntimeHostPreflight(source: source()).check()
        #expect(report.results == [
            .architectureSupported(.appleSilicon), .macOSSupported(SemanticVersion([26, 4, 1])),
            .memorySufficient(bytes: 34_359_738_368), .diskSufficient(bytes: 300_000_000_000),
            .codexInstalled(version: SemanticVersion([1, 2]), build: nil),
        ])
        #expect(report.canProceed)
        #expect(report.powerSource == .battery)
        #expect(report.checkedAt == Date(timeIntervalSince1970: 10))
        #expect(report.storage.runtimeDownloadEstimateBytes == 50_000_000)
        #expect(report.storage.restoreImageEstimateBytes == 16_000_000_000)
        #expect(report.storage.guestDiskBytes == 160_000_000_000)
        #expect(report.storage.firstSetupAllowanceBytes == 200_000_000_000)
    }

    @Test func basicFactsCannotSubstituteForUnavailableDedicatedProbes() {
        let misleading = HostProbeSnapshot(cpuArchitecture: .appleSilicon,
            operatingSystemVersion: SemanticVersion([26, 4, 1]), physicalMemoryBytes: 34_359_738_368,
            disk: .available(bytes: .max), codexDesktop: .installed(version: nil, build: nil))
        let report = RuntimeHostPreflight(source: source(facts: misleading,
            disk: .unavailable(.storageRootUnknown), codex: .unavailable)).check()
        #expect(report.result(.freeDisk) == .diskUnavailable(.storageRootUnknown))
        #expect(report.result(.codexDesktop) == .codexUnavailable)
        #expect(!report.canProceed)
    }

    @Test func healthyDiskAndAppCannotInventMissingOSFacts() {
        let report = RuntimeHostPreflight(source: source(facts: HostProbeSnapshot())).check()
        #expect(report.result(.architecture) == .architectureUnknown)
        #expect(report.result(.macOSVersion) == .macOSUnknown)
        #expect(report.result(.memory) == .memoryUnknown)
        #expect(report.powerSource == .unknown)
        #expect(!report.canProceed)
    }

    @Test(arguments: HostProbeError.allCases)
    func preservesEveryStorageFailure(_ failure: HostProbeError) {
        let report = RuntimeHostPreflight(source: source(disk: .unavailable(failure), codex: .notFound)).check()
        #expect(report.result(.freeDisk) == .diskUnavailable(failure))
        #expect(report.result(.codexDesktop) == .codexNotFound)
        #expect(!report.canProceed)
    }

    @Test(arguments: [
        (CodexDesktopObservation.notFound, PreflightResult.codexNotFound, true),
        (.unavailable, .codexUnavailable, false),
        (.installed(version: nil, build: nil), .codexInstalled(version: nil, build: nil), true),
        (.installed(version: SemanticVersion([3]), build: SemanticVersion([9])),
         .codexInstalled(version: SemanticVersion([3]), build: SemanticVersion([9])), true),
    ])
    func retainsDiscoveryVersusMetadataMeaning(_ observed: CodexDesktopObservation,
                                              _ expected: PreflightResult, _ canProceed: Bool) {
        let report = RuntimeHostPreflight(source: source(codex: observed)).check()
        #expect(report.result(.codexDesktop) == expected)
        #expect(report.canProceed == canProceed)
    }

    @Test func servicePolicyAndPresetAreCapturedTogether() throws {
        var policy = ResourcePolicy()
        policy.firstSetupAllowanceBytes = 400_000_000_000
        policy.restoreImageEstimateBytes = 7
        let preset = try #require(ResourcePreset(name: "Service choice", memoryBytes: 8_589_934_592,
            cpuCount: 2, diskBytes: 99, verification: .planBaseline))
        let check = RuntimeHostPreflight(source: source(), policy: policy, preset: preset)
        policy.firstSetupAllowanceBytes = 1 // Caller changes cannot rewrite an existing check.
        let report = check.check()
        #expect(report.result(.freeDisk) == .insufficientDisk(requiredBytes: 400_000_000_000,
                                                           availableBytes: 300_000_000_000))
        #expect(report.storage.firstSetupAllowanceBytes == 400_000_000_000)
        #expect(report.storage.restoreImageEstimateBytes == 7)
        #expect(report.storage.guestDiskBytes == 99)
        #expect(!report.canProceed)
    }

    @Test func everyRefreshRereadsSourcesAndDatesOnlyTheCompletedCollection() {
        let trace = Trace()
        let facts = Self.facts
        let check = RuntimeHostPreflight(source: .init(
            hostFacts: { trace.record(.host); return facts },
            disk: { trace.record(.disk); return trace.disk.withLock { $0 } },
            codex: { trace.record(.codex); return .notFound },
            now: { trace.record(.clock); return trace.date.withLock { $0 } }
        ))
        #expect(trace.steps.withLock { $0.isEmpty })
        let first = check.check()
        trace.disk.withLock { $0 = .available(bytes: 0) }
        trace.date.withLock { $0 = Date(timeIntervalSince1970: 20) }
        let second = check.check()
        #expect(trace.steps.withLock { $0 } == [.host, .disk, .codex, .clock, .host, .disk, .codex, .clock])
        #expect(first.canProceed)
        #expect(first.checkedAt == Date(timeIntervalSince1970: 10))
        #expect(second.result(.freeDisk) == .insufficientDisk(requiredBytes: 200_000_000_000, availableBytes: 0))
        #expect(second.checkedAt == Date(timeIntervalSince1970: 20))
        #expect(!second.canProceed)
    }

    @Test func reportEncodingExposesOnlyTheDisplayContract() throws {
        let report = RuntimeHostPreflight(source: source()).check()
        let bytes = try JSONEncoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["results", "storage", "powerSource", "checkedAt"])
        #expect(try JSONDecoder().decode(PreflightReport.self, from: bytes) == report)
        #expect(bytes.count < 4_096) // Example payload, not the future native admission bound.
    }

    private static var facts: HostProbeSnapshot {
        HostProbeSnapshot(cpuArchitecture: .appleSilicon, operatingSystemVersion: SemanticVersion([26, 4, 1]),
            physicalMemoryBytes: 34_359_738_368, powerSource: .battery)
    }
    private func source(facts: HostProbeSnapshot = RuntimeHostPreflightTests.facts,
                        disk: HostDiskObservation = .available(bytes: 300_000_000_000),
                        codex: CodexDesktopObservation = .installed(version: SemanticVersion([1, 2]), build: nil))
        -> RuntimeHostPreflight.Source {
        .init(hostFacts: { facts }, disk: { disk }, codex: { codex }, now: { Date(timeIntervalSince1970: 10) })
    }

    private final class Trace: Sendable {
        enum Step: Equatable, Sendable { case host, disk, codex, clock }
        let steps = Mutex<[Step]>([])
        let disk = Mutex<HostDiskObservation>(.available(bytes: 300_000_000_000))
        let date = Mutex(Date(timeIntervalSince1970: 10))
        func record(_ step: Step) { steps.withLock { $0.append(step) } }
    }
}
