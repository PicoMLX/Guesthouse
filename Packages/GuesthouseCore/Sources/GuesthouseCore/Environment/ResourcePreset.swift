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

    /// Set only through the initializer or the decoder, both of which refuse values a VM
    /// cannot be configured with, so an invalid preset cannot be assembled after the fact.
    public private(set) var name: String
    public private(set) var memoryBytes: UInt64
    public private(set) var cpuCount: Int
    /// Logical (sparse) guest disk capacity. Actual consumption is usually far lower.
    public private(set) var diskBytes: UInt64
    public private(set) var verification: Verification

    /// A preset with no name, a non-positive processor count, or no memory or disk cannot
    /// start a VM, so such values are refused rather than carried into the runtime.
    public init?(name: String, memoryBytes: UInt64, cpuCount: Int, diskBytes: UInt64, verification: Verification) {
        guard !name.isEmpty, cpuCount > 0, memoryBytes > 0, diskBytes > 0 else { return nil }
        self.init(valid: name, memoryBytes: memoryBytes, cpuCount: cpuCount, diskBytes: diskBytes, verification: verification)
    }

    /// The fixed presets below, whose values are known good.
    private init(valid name: String, memoryBytes: UInt64, cpuCount: Int, diskBytes: UInt64, verification: Verification) {
        self.name = name
        self.memoryBytes = memoryBytes
        self.cpuCount = cpuCount
        self.diskBytes = diskBytes
        self.verification = verification
    }

    private enum CodingKeys: String, CodingKey { case name, memoryBytes, cpuCount, diskBytes, verification }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let preset = ResourcePreset(
            name: try c.decode(String.self, forKey: .name),
            memoryBytes: try c.decode(UInt64.self, forKey: .memoryBytes),
            cpuCount: try c.decode(Int.self, forKey: .cpuCount),
            diskBytes: try c.decode(UInt64.self, forKey: .diskBytes),
            verification: try c.decode(Verification.self, forKey: .verification)
        ) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a preset needs a name and positive processor, memory, and disk values"))
        }
        self = preset
    }

    public static let gibibyte: UInt64 = 1 << 30
    public static let gigabyte: UInt64 = 1_000_000_000

    /// One VM on a 32 GB host. 16 GiB leaves headroom for host macOS and Codex desktop.
    public static let recommended = ResourcePreset(
        valid: "Recommended",
        memoryBytes: 16 * gibibyte,
        cpuCount: 6,
        diskBytes: 160 * gigabyte,
        verification: .planBaseline
    )

    /// Two concurrent VMs at 12 GiB each. An experiment for the second slot, not a guarantee
    /// for every Xcode or MLX project (MVP-PLAN.md §4).
    public static let dualVMExperiment = ResourcePreset(
        valid: "Dual-VM experiment",
        memoryBytes: 12 * gibibyte,
        cpuCount: 4,
        diskBytes: 160 * gigabyte,
        verification: .experimental
    )
}
