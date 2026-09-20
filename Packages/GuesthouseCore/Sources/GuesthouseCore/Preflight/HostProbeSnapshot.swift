/// Host facts supplied by the runtime-owned probe (#12, MVP-PLAN.md §§2–3).
/// No syscalls, app lookup, filesystem access or automatic diagnostics are performed here.
public enum PowerSource: String, Codable, Hashable, Sendable {
    case externalPower, battery, unknown
}

/// The selected runtime storage root's capacity, not the GUI container's proxy volume.
/// A numeric observation is not retained volume identity or authority to mutate a path.
public enum HostDiskObservation: Codable, Hashable, Sendable {
    case available(bytes: UInt64)
    case unavailable(HostProbeError)
}

/// Discovery and metadata are different facts: missing metadata does not mean missing app.
/// Versions are bounded dotted numeric observations, not opaque bundle text. Nonconforming
/// metadata is unknown. Exact private compatibility identity remains in ObservedTuple; this
/// summary is not evidence of a verified desktop connection and carries no application path.
public enum CodexDesktopObservation: Codable, Hashable, Sendable {
    case notFound
    case unavailable
    case installed(version: SemanticVersion?, build: SemanticVersion?)
}

/// Immutable input to the pure preflight evaluator. Every default means unobserved, never
/// a fabricated healthy host. Missing OS/memory observations remain distinct from version 0
/// or zero bytes. Decoders reject unknown enum cases; ignored fields are not re-exported.
/// This is not a native-message size/admission validator or a persisted compatibility record.
public struct HostProbeSnapshot: Codable, Hashable, Sendable {
    public let cpuArchitecture: CPUArchitecture
    public let operatingSystemVersion: SemanticVersion?
    public let physicalMemoryBytes: UInt64?
    public let powerSource: PowerSource
    public let disk: HostDiskObservation
    public let codexDesktop: CodexDesktopObservation

    public init(
        cpuArchitecture: CPUArchitecture = .unknown,
        operatingSystemVersion: SemanticVersion? = nil,
        physicalMemoryBytes: UInt64? = nil,
        powerSource: PowerSource = .unknown,
        disk: HostDiskObservation = .unavailable(.storageRootUnknown),
        codexDesktop: CodexDesktopObservation = .unavailable
    ) {
        self.cpuArchitecture = cpuArchitecture
        self.operatingSystemVersion = operatingSystemVersion
        self.physicalMemoryBytes = physicalMemoryBytes
        self.powerSource = powerSource
        self.disk = disk
        self.codexDesktop = codexDesktop
    }
}
