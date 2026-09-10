import Foundation

/// Planning summary for MVP-PLAN.md §2. This is not a verified path, download quote,
/// storage authorization, or proof of sparse-disk physical consumption.
public struct StorageSummary: Codable, Hashable, Sendable {
    public let runtimeDownloadEstimateBytes: UInt64
    public let restoreImageEstimateBytes: UInt64
    public let guestDiskBytes: UInt64
    public let firstSetupAllowanceBytes: UInt64

    public init(policy: ResourcePolicy = .standard, preset: ResourcePreset = .recommended) {
        runtimeDownloadEstimateBytes = policy.runtimeDownloadEstimateBytes
        restoreImageEstimateBytes = policy.restoreImageEstimateBytes
        guestDiskBytes = preset.diskBytes
        firstSetupAllowanceBytes = policy.firstSetupAllowanceBytes
    }

    public var locationDescription: String {
        "VM files are planned for Guesthouse's runtime-managed Application Support folder for this account. The runtime must verify the storage location before setup."
    }
}

/// A display/evaluation result, not runtime mutation admission or a native framing validator.
/// Immutable values preserve the checked snapshot; callers must refresh before proceeding.
/// Codable preserves typed facts, not trust: only an authenticated runtime may supply them.
public struct PreflightReport: Codable, Hashable, Sendable {
    public let results: [PreflightResult]
    public let storage: StorageSummary
    public let powerSource: PowerSource
    public let checkedAt: Date

    public init(results: [PreflightResult], storage: StorageSummary, powerSource: PowerSource, checkedAt: Date) {
        self.results = results
        self.storage = storage
        self.powerSource = powerSource
        self.checkedAt = checkedAt
    }

    /// Empty, partial, duplicated and blocking reports cannot proceed. A warning is an answer;
    /// an unavailable observation is not. Actual runtime safety checks remain mandatory.
    public var canProceed: Bool {
        results.count == PreflightCheckKind.allCases.count
            && Set(results.map(\.kind)) == Set(PreflightCheckKind.allCases)
            && !results.contains(where: \.isBlocking)
    }

    public func result(_ kind: PreflightCheckKind) -> PreflightResult? {
        results.first { $0.kind == kind }
    }
}

/// #61's retained evaluator adapted to #170's runtime-supplied observations. This pure
/// function performs no host I/O; policy and observations must come from the runtime boundary.
public enum PreflightCheck: Sendable {
    public static func run(
        snapshot: HostProbeSnapshot,
        policy: ResourcePolicy = .standard,
        preset: ResourcePreset = .recommended,
        now: Date = Date()
    ) -> PreflightReport {
        let architecture: PreflightResult
        if snapshot.cpuArchitecture == .unknown {
            architecture = .architectureUnknown
        } else if snapshot.cpuArchitecture == policy.requiredArchitecture {
            architecture = .architectureSupported(snapshot.cpuArchitecture)
        } else {
            architecture = .architectureMismatch(found: snapshot.cpuArchitecture, required: policy.requiredArchitecture)
        }

        let operatingSystem: PreflightResult
        if let version = snapshot.operatingSystemVersion {
            operatingSystem = version >= policy.minimumMacOS
                ? .macOSSupported(version) : .macOSTooOld(found: version, minimum: policy.minimumMacOS)
        } else {
            operatingSystem = .macOSUnknown
        }

        let memory: PreflightResult
        if let bytes = snapshot.physicalMemoryBytes {
            do {
                try MemoryPreflight.check(physicalMemoryBytes: bytes, preset: preset, policy: policy)
                memory = bytes >= policy.recommendedMemoryBytes
                    ? .memorySufficient(bytes: bytes)
                    : .memoryLimited(foundBytes: bytes, recommendedBytes: policy.recommendedMemoryBytes)
            } catch {
                memory = .memoryFailure(error)
            }
        } else {
            memory = .memoryUnknown
        }

        let disk: PreflightResult = switch snapshot.disk {
        case .available(let bytes):
            bytes >= policy.firstSetupAllowanceBytes
                ? .diskSufficient(bytes: bytes)
                : .insufficientDisk(requiredBytes: policy.firstSetupAllowanceBytes, availableBytes: bytes)
        case .unavailable(let error): .diskUnavailable(error)
        }
        let codex: PreflightResult = switch snapshot.codexDesktop {
        case .installed(let version, let build): .codexInstalled(version: version, build: build)
        case .notFound: .codexNotFound
        case .unavailable: .codexUnavailable
        }
        return PreflightReport(
            results: [architecture, operatingSystem, memory, disk, codex],
            storage: StorageSummary(policy: policy, preset: preset),
            powerSource: snapshot.powerSource,
            checkedAt: now
        )
    }
}
