/// Guest resource allocation for one environment.
///
/// The numbers come from MVP-PLAN.md §4 ("Version and resource policy") and are planning
/// estimates. They stay estimates until the phase-0 complete-path run records measured peaks;
/// do not present them to users as guarantees.
public struct ResourcePreset: Codable, Hashable, Sendable {
    /// How much trust the preset deserves.
    public enum Verification: String, Codable, Hashable, Sendable {
        /// The plan's baseline for the 32 GB reference Mac. An estimate, not a measurement.
        case planBaseline
        /// Explicitly unverified. Only for the dual-VM memory-pressure experiment.
        case experimental
    }

    public var name: String
    public var memoryBytes: UInt64
    public var cpuCount: Int
    /// Logical (sparse) guest disk capacity. Actual consumption is usually far lower.
    public var diskBytes: UInt64
    public var verification: Verification

    public init(name: String, memoryBytes: UInt64, cpuCount: Int, diskBytes: UInt64, verification: Verification) {
        self.name = name
        self.memoryBytes = memoryBytes
        self.cpuCount = cpuCount
        self.diskBytes = diskBytes
        self.verification = verification
    }

    public static let gibibyte: UInt64 = 1 << 30
    public static let gigabyte: UInt64 = 1_000_000_000

    /// One VM on a 32 GB host. 16 GiB leaves headroom for host macOS and Codex desktop.
    public static let recommended = ResourcePreset(
        name: "Recommended",
        memoryBytes: 16 * gibibyte,
        cpuCount: 6,
        diskBytes: 160 * gigabyte,
        verification: .planBaseline
    )

    /// Two concurrent VMs at 12 GiB each. An experiment for the second slot, not a guarantee
    /// for every Xcode or MLX project (MVP-PLAN.md §4).
    public static let dualVMExperiment = ResourcePreset(
        name: "Dual-VM experiment",
        memoryBytes: 12 * gibibyte,
        cpuCount: 4,
        diskBytes: 160 * gigabyte,
        verification: .experimental
    )
}
