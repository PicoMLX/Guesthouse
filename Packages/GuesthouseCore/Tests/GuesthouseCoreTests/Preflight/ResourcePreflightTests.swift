import Foundation
import Testing
@testable import GuesthouseCore

/// #61's arithmetic regressions are independent of host I/O and the later report/wizard.
struct ResourcePreflightTests {
    @Test func standardPolicyRetainsThePlansExplicitPlanningAllowances() {
        let policy = ResourcePolicy.standard
        #expect(policy.requiredArchitecture == .appleSilicon)
        #expect(policy.minimumMacOS == SemanticVersion([26, 4]))
        #expect(policy.minimumMemoryBytes == 17_179_869_184)
        #expect(policy.hostMemoryHeadroomBytes == 8_589_934_592)
        #expect(policy.recommendedMemoryBytes == 34_359_738_368)
        #expect(policy.firstSetupAllowanceBytes == 200_000_000_000)
        #expect(policy.largeOperationMarginBytes == 10_000_000_000)
        #expect(policy.runtimeDownloadEstimateBytes == 50_000_000)
        #expect(policy.restoreImageEstimateBytes == 16_000_000_000)
        #expect(policy.isWellFormed)
    }

    @Test func selectedGuestMustLeaveTheConfiguredHostHeadroom() {
        #expect(throws: GuesthouseError.unsupportedHost(.insufficientMemory(
            foundBytes: 17_179_869_184, minimumBytes: 25_769_803_776
        ))) { try MemoryPreflight.check(physicalMemoryBytes: 16 * ResourcePreset.gibibyte) }
    }

    @Test(arguments: [UInt64(24), 32, 64])
    func satisfyingTheBlockingFloorDoesNotRequireTheRecommendation(gibibytes: UInt64) throws {
        try MemoryPreflight.check(physicalMemoryBytes: gibibytes * ResourcePreset.gibibyte)
    }

    @Test func aContradictoryRecommendationCannotBypassTheBlockingMinimum() {
        var policy = ResourcePolicy.standard
        policy.minimumMemoryBytes = 48 * ResourcePreset.gibibyte
        #expect(!policy.isWellFormed)
        #expect(throws: GuesthouseError.unsupportedHost(.insufficientMemory(
            foundBytes: 34_359_738_368, minimumBytes: 51_539_607_552
        ))) { try MemoryPreflight.check(physicalMemoryBytes: 32 * ResourcePreset.gibibyte, policy: policy) }
    }

    @Test(arguments: [UInt64(0), 32 * ResourcePreset.gibibyte, .max])
    func memoryAdditionOverflowAlwaysBlocks(available: UInt64) {
        var policy = ResourcePolicy.standard
        policy.hostMemoryHeadroomBytes = .max
        #expect(throws: GuesthouseError.unsupportedHost(.insufficientMemory(
            foundBytes: available, minimumBytes: .max
        ))) { try MemoryPreflight.check(physicalMemoryBytes: available, policy: policy) }
    }

    @Test func exactlyRepresentableMaximumMemoryIsNotMistakenForOverflow() throws {
        var policy = ResourcePolicy.standard
        policy.hostMemoryHeadroomBytes = 8
        let preset = try #require(ResourcePreset(name: "Boundary fixture", memoryBytes: .max - 8,
                                                cpuCount: 1, diskBytes: 1, verification: .experimental))
        try MemoryPreflight.check(physicalMemoryBytes: .max, preset: preset, policy: policy)
        #expect(throws: GuesthouseError.unsupportedHost(.insufficientMemory(
            foundBytes: .max - 1, minimumBytes: .max
        ))) { try MemoryPreflight.check(physicalMemoryBytes: .max - 1, preset: preset, policy: policy) }
    }

    @Test(arguments: [
        (UInt64(49), UInt64(40), UInt64(10), UInt64(50)),
        (0, 0, 1, 1), (.max, .max, 1, .max), (.max, .max - 1, 2, .max),
    ])
    func diskRefusalsPreserveTheFullRequirement(_ values: (UInt64, UInt64, UInt64, UInt64)) {
        let (available, required, margin, needed) = values
        var policy = ResourcePolicy.standard
        policy.largeOperationMarginBytes = margin
        #expect(throws: GuesthouseError.insufficientDisk(requiredBytes: needed, availableBytes: available)) {
            try LargeOperationPreflight.check(freeBytes: available, requiredBytes: required, policy: policy)
        }
    }

    @Test(arguments: [
        (UInt64(50), UInt64(40), UInt64(10)),
        (51, 40, 10), (0, 0, 0), (.max, .max, 0), (.max, .max - 1, 1),
    ])
    func exactAndLargerDiskBudgetsPass(_ values: (UInt64, UInt64, UInt64)) throws {
        let (available, required, margin) = values
        var policy = ResourcePolicy.standard
        policy.largeOperationMarginBytes = margin
        try LargeOperationPreflight.check(freeBytes: available, requiredBytes: required, policy: policy)
    }

    @Test func theDefaultLargeOperationMarginIsAppliedInBytes() throws {
        try LargeOperationPreflight.check(freeBytes: 60_000_000_000, requiredBytes: 40_000_000_000)
        #expect(throws: GuesthouseError.insufficientDisk(requiredBytes: 50_000_000_000, availableBytes: 45_000_000_000)) {
            try LargeOperationPreflight.check(freeBytes: 45_000_000_000, requiredBytes: 40_000_000_000)
        }
    }

    @Test func overflowFailureKeepsTypedRecoveryAndFullRangeEncoding() throws {
        let thrown = #expect(throws: GuesthouseError.self) {
            try LargeOperationPreflight.check(freeBytes: 512, requiredBytes: .max)
        }
        let failure = try #require(thrown)
        #expect(failure.userMessage.contains("18446744073709551615"))
        #expect(failure.recoveryActions == [.freeDiskSpace, .inspectState, .cancel])
        #expect(try JSONDecoder().decode(GuesthouseError.self, from: JSONEncoder().encode(failure)) == failure)
    }
}
