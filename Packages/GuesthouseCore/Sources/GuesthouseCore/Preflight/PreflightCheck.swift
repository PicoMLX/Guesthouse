import Foundation

public enum PreflightCheckKind: String, Codable, Hashable, Sendable, CaseIterable {
    case architecture
    case macOSVersion
    case memory
    case freeDisk
    case codexDesktop
}

public struct PreflightResult: Codable, Hashable, Sendable {
    public enum Outcome: Codable, Hashable, Sendable {
        case pass(detail: String)
        /// Setup may continue; the detail says what the user should know.
        case warn(detail: String, recovery: [RecoveryAction])
        /// Setup cannot continue. The error carries the message and recovery actions.
        case fail(GuesthouseError)
    }

    public let kind: PreflightCheckKind
    public let outcome: Outcome

    public init(kind: PreflightCheckKind, outcome: Outcome) {
        self.kind = kind
        self.outcome = outcome
    }

    public var isFailure: Bool {
        if case .fail = outcome { return true }
        return false
    }
}

/// "What will be downloaded and where the VM will live" (MVP-PLAN.md §2, step 1).
public struct StorageSummary: Codable, Hashable, Sendable {
    public var storageRootPath: String
    public var runtimeDownloadEstimateBytes: UInt64
    public var restoreImageEstimateBytes: UInt64
    public var guestDiskBytes: UInt64
    public var firstSetupAllowanceBytes: UInt64

    public init(storageRootPath: String, runtimeDownloadEstimateBytes: UInt64, restoreImageEstimateBytes: UInt64, guestDiskBytes: UInt64, firstSetupAllowanceBytes: UInt64) {
        self.storageRootPath = storageRootPath
        self.runtimeDownloadEstimateBytes = runtimeDownloadEstimateBytes
        self.restoreImageEstimateBytes = restoreImageEstimateBytes
        self.guestDiskBytes = guestDiskBytes
        self.firstSetupAllowanceBytes = firstSetupAllowanceBytes
    }
}

public struct PreflightReport: Codable, Hashable, Sendable {
    public var results: [PreflightResult]
    public var storage: StorageSummary
    public var powerSource: PowerSource
    public var checkedAt: Date

    public init(results: [PreflightResult], storage: StorageSummary, powerSource: PowerSource, checkedAt: Date) {
        self.results = results
        self.storage = storage
        self.powerSource = powerSource
        self.checkedAt = checkedAt
    }

    /// True when no check failed. Warnings do not block.
    public var canProceed: Bool { !results.contains(where: \.isFailure) }

    public func result(_ kind: PreflightCheckKind) -> PreflightResult? {
        results.first { $0.kind == kind }
    }
}

/// The "Check this Mac" step. Pure given a probe; every threshold comes from `ResourcePolicy`.
public enum PreflightCheck {
    public static func run(
        probe: any HostProbe,
        policy: ResourcePolicy = .standard,
        storageRoot: URL,
        preset: ResourcePreset = .recommended,
        now: Date = Date()
    ) -> PreflightReport {
        var results: [PreflightResult] = []

        let architecture = probe.cpuArchitecture
        let architectureOutcome: PreflightResult.Outcome = switch architecture {
        case policy.requiredArchitecture: .pass(detail: "Apple silicon")
        case .unknown: .fail(.unsupportedHost(.architectureUnknown))
        default: .fail(.unsupportedHost(.notAppleSilicon))
        }
        results.append(PreflightResult(kind: .architecture, outcome: architectureOutcome))

        let version = probe.operatingSystemVersion
        let build = probe.operatingSystemBuild.map { " (\($0))" } ?? ""
        results.append(PreflightResult(kind: .macOSVersion, outcome: version >= policy.minimumMacOS
            ? .pass(detail: "macOS \(version)\(build)")
            : .fail(.unsupportedHost(.macOSTooOld(found: SanitizedText(version.description), minimum: SanitizedText(policy.minimumMacOS.description))))))

        let memory = probe.physicalMemoryBytes
        let memoryOutcome: PreflightResult.Outcome
        // The guest's allocation plus the host's headroom is the real floor; the policy minimum
        // applies on top of it.
        let floor = max(policy.minimumMemoryBytes, preset.memoryBytes.addingReportingOverflow(policy.hostMemoryHeadroomBytes).partialValue)
        if memory < floor {
            memoryOutcome = .fail(.unsupportedHost(.insufficientMemory(foundBytes: memory, minimumBytes: floor)))
        } else if memory >= policy.recommendedMemoryBytes {
            memoryOutcome = .pass(detail: "\(format(memory, memory: true)) of memory")
        } else {
            memoryOutcome = .warn(
                detail: "\(format(memory, memory: true)) of memory. \(format(policy.recommendedMemoryBytes, memory: true)) is recommended; with less, run one development Mac at a time and expect memory pressure during large builds.",
                recovery: []
            )
        }
        results.append(PreflightResult(kind: .memory, outcome: memoryOutcome))

        let diskOutcome: PreflightResult.Outcome
        do {
            let free = try probe.freeBytes(at: storageRoot)
            if free >= policy.firstSetupAllowanceBytes {
                diskOutcome = .pass(detail: "\(format(free)) free on the volume that will hold the development Mac")
            } else {
                diskOutcome = .fail(.insufficientDisk(requiredBytes: policy.firstSetupAllowanceBytes, availableBytes: free, volumePath: SanitizedText(storageRoot.path)))
            }
        } catch {
            diskOutcome = .warn(detail: "Free space on \(GuesthouseError.sanitize(storageRoot.path, limit: 200)) could not be determined.", recovery: [.retry])
        }
        results.append(PreflightResult(kind: .freeDisk, outcome: diskOutcome))

        let codex = policy.codexDesktopBundleIdentifiers.lazy.compactMap(probe.installedApplication(bundleIdentifier:)).first
        results.append(PreflightResult(kind: .codexDesktop, outcome: codex.map { app in
            // Bundle metadata and paths come from another app on disk: normalize and bound them
            // before they become UI text, as every externally sourced value is.
            let version = [app.version.map { GuesthouseError.sanitize($0) }, app.build.map { "(\(GuesthouseError.sanitize($0)))" }].compactMap { $0 }.joined(separator: " ")
            return .pass(detail: "Codex desktop \(version.isEmpty ? "found" : version) at \(GuesthouseError.sanitize(app.url.path, limit: 200))")
        } ?? .warn(detail: "Codex desktop is not installed. Guesthouse can prepare a development Mac without it, but you will need it to open a workspace in Codex.", recovery: [])))

        let storage = StorageSummary(
            storageRootPath: GuesthouseError.sanitize(storageRoot.path, limit: 400),
            runtimeDownloadEstimateBytes: policy.runtimeDownloadEstimateBytes,
            restoreImageEstimateBytes: policy.restoreImageEstimateBytes,
            guestDiskBytes: preset.diskBytes,
            firstSetupAllowanceBytes: policy.firstSetupAllowanceBytes
        )
        return PreflightReport(results: results, storage: storage, powerSource: probe.powerSource, checkedAt: now)
    }

    private static func format(_ bytes: UInt64, memory: Bool = false) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: memory ? .memory : .file)
    }
}

/// Free-space check before every download, import, or clone, not only at first launch
/// (MVP-PLAN.md §4: "Check free space before each large operation").
public enum LargeOperationPreflight {
    public static func check(
        freeBytes: UInt64,
        requiredBytes: UInt64,
        volumePath: String,
        policy: ResourcePolicy = .standard
    ) throws(GuesthouseError) {
        // A requirement that cannot be represented cannot be satisfied.
        let (needed, overflow) = requiredBytes.addingReportingOverflow(policy.largeOperationMarginBytes)
        guard !overflow, freeBytes >= needed else {
            throw .insufficientDisk(requiredBytes: needed, availableBytes: freeBytes, volumePath: SanitizedText(volumePath))
        }
    }
}
