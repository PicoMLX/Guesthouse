/// Pure resource checks migrated from retained #61 (MVP-PLAN.md §§2 and 4).
/// A caller supplies observations; these functions neither probe the host nor authorize a
/// mutation. The runtime must remeasure its actual destination before each large operation.
public enum LargeOperationPreflight: Sendable {
    public static func check(
        freeBytes: UInt64,
        requiredBytes: UInt64,
        policy: ResourcePolicy = .standard
    ) throws(GuesthouseError) {
        let (sum, overflow) = requiredBytes.addingReportingOverflow(policy.largeOperationMarginBytes)
        let needed = overflow ? UInt64.max : sum
        // Even UInt64.max available bytes cannot satisfy an unrepresentable requirement.
        guard !overflow, freeBytes >= needed else {
            throw .insufficientDisk(requiredBytes: needed, availableBytes: freeBytes)
        }
    }
}

/// Blocking memory floor extracted from #61's evaluator. Passing this check does not imply
/// recommended performance; a report still warns below policy.recommendedMemoryBytes.
/// This evaluates one selected guest, not admission or the combined cost of two running VMs.
public enum MemoryPreflight: Sendable {
    public static func check(
        physicalMemoryBytes: UInt64,
        preset: ResourcePreset = .recommended,
        policy: ResourcePolicy = .standard
    ) throws(GuesthouseError) {
        let (required, overflow) = preset.memoryBytes.addingReportingOverflow(policy.hostMemoryHeadroomBytes)
        let floor = overflow ? UInt64.max : max(policy.minimumMemoryBytes, required)
        // Test overflow itself: comparing UInt64.max against a saturated floor is insufficient.
        guard !overflow, physicalMemoryBytes >= floor else {
            throw .unsupportedHost(.insufficientMemory(foundBytes: physicalMemoryBytes, minimumBytes: floor))
        }
    }
}
