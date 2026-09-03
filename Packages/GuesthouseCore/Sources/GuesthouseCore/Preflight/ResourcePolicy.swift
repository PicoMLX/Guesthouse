/// Every threshold the preflight and the large-operation checks use, in one place.
///
/// Numbers come from MVP-PLAN.md §4 ("Version and resource policy") and are planning
/// estimates until phase 0 records measured peaks. Change them here, nowhere else.
public struct ResourcePolicy: Hashable, Sendable {
    public var requiredArchitecture: CPUArchitecture = .appleSilicon
    /// The app's deployment target; older hosts cannot run it anyway, but a preflight that
    /// somehow runs on one must say so plainly.
    public var minimumMacOS = SemanticVersion([26, 4])
    /// Below this the host cannot run a development Mac alongside anything else.
    public var minimumMemoryBytes: UInt64 = 16 * ResourcePreset.gibibyte
    /// What the host keeps for itself beside the guest's allocation. A Mac whose memory is
    /// below the guest allocation plus this headroom is blocked, not warned (MVP-PLAN.md §4).
    public var hostMemoryHeadroomBytes: UInt64 = 8 * ResourcePreset.gibibyte
    /// Below this the preflight warns; the reference Mac has 32 GB.
    public var recommendedMemoryBytes: UInt64 = 32 * ResourcePreset.gibibyte
    /// Free space needed for the first setup: runtime, restore image, temporary extraction,
    /// and the sparse guest disk's early growth (§4: "roughly 200 GB").
    public var firstSetupAllowanceBytes: UInt64 = 200 * ResourcePreset.gigabyte
    /// Headroom added to every large operation's own requirement.
    public var largeOperationMarginBytes: UInt64 = 10 * ResourcePreset.gigabyte
    /// Download estimates shown before the first setup starts. Estimates, not measurements.
    public var runtimeDownloadEstimateBytes: UInt64 = 50 * ResourcePreset.megabyte
    public var restoreImageEstimateBytes: UInt64 = 16 * ResourcePreset.gigabyte
    /// Bundle identifiers that count as the Codex desktop app, in preference order. The plan
    /// calls the host application "Codex desktop"; current OpenAI documentation places the
    /// connection UI in the ChatGPT desktop app. Gate #41 confirms the identifier.
    public var codexDesktopBundleIdentifiers: [String] = ["com.openai.chat", "com.openai.codex"]

    public init() {}

    public static let standard = ResourcePolicy()

    /// A policy whose blocking minimum exceeds its recommendation is contradictory; the
    /// preflight evaluates the minimum first regardless, and this check makes the mistake
    /// visible in tests.
    public var isWellFormed: Bool { minimumMemoryBytes <= recommendedMemoryBytes }
}

extension ResourcePreset {
    public static let megabyte: UInt64 = 1_000_000
}
