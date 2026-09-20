import Foundation
import GuesthouseCore

/// Runtime-owned composition for #12/#61 (MVP-PLAN.md §§2–3). No GUI-selected path,
/// bundle identifier or policy crosses into this helper. It neither selects/persists a
/// replacement volume nor prepares storage. The owner supplies retained selection metadata.
/// Scheduling/admission is separate: native reads must run OUTSIDE RuntimeSessionGate and
/// native callbacks on an appropriate runtime worker, never the GUI or cooperative executor.
struct RuntimeHostPreflight: Sendable {
    struct Source: Sendable {
        let hostFacts: @Sendable () -> HostProbeSnapshot
        let disk: @Sendable () -> HostDiskObservation
        let codex: @Sendable () -> CodexDesktopObservation
        let now: @Sendable () -> Date
    }

    private let source: Source
    private let policy: ResourcePolicy
    private let preset: ResourcePreset

    /// Construction does no I/O. Missing selection remains unavailable on every check.
    init(storageRoot: URL?, expectedVolume: UUID?,
         policy: ResourcePolicy = .standard, preset: ResourcePreset = .recommended) {
        let storage = SystemStorageProbe(storageRoot: storageRoot, expectedVolume: expectedVolume)
        self.init(source: Source(
            hostFacts: { SystemHostFactsProbe().snapshot() },
            disk: { storage.observe() },
            codex: { SystemCodexDesktopProbe().observe() },
            now: { Date() }
        ), policy: policy, preset: preset)
    }

    // Typed fixture injection, not a replacement public/native dispatch interface.
    init(source: Source, policy: ResourcePolicy = .standard, preset: ResourcePreset = .recommended) {
        self.source = source
        self.policy = policy
        self.preset = preset
    }

    /// Each call rereads all three sources. The timestamp marks collection completion,
    /// not an atomic host snapshot, freshness lease or authorization to create/start a VM.
    func check() -> PreflightReport {
        let facts = source.hostFacts()
        let disk = source.disk()
        let codex = source.codex()
        let snapshot = HostProbeSnapshot(
            cpuArchitecture: facts.cpuArchitecture,
            operatingSystemVersion: facts.operatingSystemVersion,
            physicalMemoryBytes: facts.physicalMemoryBytes,
            powerSource: facts.powerSource,
            disk: disk,
            codexDesktop: codex
        )
        return PreflightCheck.run(snapshot: snapshot, policy: policy, preset: preset, now: source.now())
    }
}
